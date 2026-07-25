defmodule Polyphony.Director.BeatPolicy do
  @moduledoc """
  The beat-loop stopping rule (§10), as a pure decision.

  The loop is: packet commits → beat opens → Director decides → cast generate
  serially → Director decides again → eventually yields to the user. Two things
  keep it from running away, and one keeps causality intact:

    * a **hard depth cap** (~3 beats) so a runaway argument can't monopolize the
      session;
    * the Director's explicit `:yield_to_user`;
    * **beat truncation on membership change** (§10): if an accepted exit/entry
      lands, the remaining cast do *not* generate, the beat closes, and the
      Director re-decides against the new membership.

  Membership truncation takes precedence over everything — a beat whose cast list
  is now wrong must not keep generating into a room someone just left.
  """

  @default_max_depth 3

  @type action :: :continue | :yield_to_user | :truncate

  @type input :: %{
          optional(:depth) => non_neg_integer(),
          optional(:control) => :continue | :yield_to_user,
          optional(:membership_changed) => boolean(),
          optional(:max_depth) => pos_integer()
        }

  @doc "Decide what the loop does after a beat."
  @spec next(input()) :: action()
  def next(input) do
    depth = Map.get(input, :depth, 0)
    control = Map.get(input, :control, :continue)
    membership_changed = Map.get(input, :membership_changed, false)
    max_depth = Map.get(input, :max_depth, @default_max_depth)

    cond do
      membership_changed -> :truncate
      control == :yield_to_user -> :yield_to_user
      depth + 1 >= max_depth -> :yield_to_user
      true -> :continue
    end
  end

  @doc "The default hard depth cap."
  def default_max_depth, do: @default_max_depth
end
