defmodule Polyphony.MembershipSet do
  @moduledoc """
  A pure, in-memory materialization of scene membership as intervals (§8).

  Membership is a **projection** over `CharacterEntered`/`CharacterExited`
  events — it is never self-reported (foundational rule 4). This module is the
  reference implementation of that fold: the Postgres `scene_memberships` read
  model (`Polyphony.Projectors.SceneMemberships`) must answer `member_at?/3`
  identically, and the test suite pins both to the same interval semantics.

  Intervals are **half-open**: `[entered_beat, exited_beat)`. A character is a
  member at `beat` iff `entered_beat <= beat < exited_beat` (or the interval is
  still open). Re-entry is simply a second interval — no special casing.
  """

  alias Polyphony.Events.{CharacterEntered, CharacterExited}

  @type interval :: %{
          scene_id: term(),
          character_id: term(),
          entered_beat: integer(),
          exited_beat: integer() | nil
        }

  @type t :: %__MODULE__{intervals: [interval()]}

  defstruct intervals: []

  @doc "Build a membership set by folding the membership events in log order."
  @spec from_events(Enumerable.t()) :: t()
  def from_events(events) do
    Enum.reduce(events, %__MODULE__{}, &apply_event(&2, &1))
  end

  @doc "Apply a single event, ignoring everything that is not a membership change."
  @spec apply_event(t(), struct()) :: t()
  def apply_event(%__MODULE__{intervals: intervals} = set, %CharacterEntered{} = e) do
    interval = %{
      scene_id: e.scene_id,
      character_id: e.character_id,
      entered_beat: e.beat,
      exited_beat: nil
    }

    %{set | intervals: intervals ++ [interval]}
  end

  def apply_event(%__MODULE__{intervals: intervals} = set, %CharacterExited{} = e) do
    # Close the most recent still-open interval for this (scene, character).
    idx =
      intervals
      |> Enum.with_index()
      |> Enum.filter(fn {i, _} ->
        i.scene_id == e.scene_id and i.character_id == e.character_id and
          is_nil(i.exited_beat)
      end)
      |> List.last()

    case idx do
      nil ->
        # Exit without a matching open entry — ignore rather than corrupt state.
        set

      {_interval, index} ->
        %{set | intervals: List.update_at(intervals, index, &%{&1 | exited_beat: e.beat})}
    end
  end

  def apply_event(%__MODULE__{} = set, _other), do: set

  @doc """
  Is `character_id` a member of `scene_id` at `beat`?

  Uses the half-open interval `[entered_beat, exited_beat)`, matching the read
  model's SQL exactly: `entered_beat <= beat AND (exited_beat IS NULL OR
  exited_beat > beat)`.
  """
  @spec member_at?(t(), term(), term(), integer()) :: boolean()
  def member_at?(%__MODULE__{intervals: intervals}, scene_id, character_id, beat) do
    Enum.any?(intervals, fn i ->
      i.scene_id == scene_id and i.character_id == character_id and
        i.entered_beat <= beat and (is_nil(i.exited_beat) or i.exited_beat > beat)
    end)
  end

  @doc """
  Return a `member_at?/3` closure suitable for `Polyphony.Visibility`.

  This is the seam that lets the *pure* set and the *Postgres* read model be
  used interchangeably — both expose the same `(scene_id, char_id, beat) ->
  boolean` shape.
  """
  @spec member_at_fun(t()) :: (term(), term(), integer() -> boolean())
  def member_at_fun(%__MODULE__{} = set) do
    fn scene_id, character_id, beat ->
      member_at?(set, scene_id, character_id, beat)
    end
  end
end
