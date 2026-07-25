defmodule Polyphony.ReadModels.Membership do
  @moduledoc """
  The `scene_memberships` interval read model (§8): schema, write path, and
  queries.

  Keeping the writes and queries here (rather than inline in the projector)
  means the exact SQL that runs in production is what the test suite exercises
  against Postgres — the projector is a thin Commanded wrapper over these
  functions, and the parity test pins `member_at?/4` to `MembershipSet`.

  Ids are stored as strings so the read model is agnostic to whether callers use
  binary ids, atoms, or UUIDs — `to_string/1` normalizes at the boundary.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "scene_memberships" do
    field(:scene_id, :string)
    field(:character_id, :string)
    field(:entered_beat, :integer)
    field(:exited_beat, :integer)
  end

  # ── Write path ─────────────────────────────────────────────────────────────

  @doc "Open a new interval for a character entering a scene."
  def enter(repo, scene_id, character_id, beat) do
    repo.insert!(%__MODULE__{
      scene_id: to_string(scene_id),
      character_id: to_string(character_id),
      entered_beat: beat,
      exited_beat: nil
    })
  end

  @doc """
  Close the most recent still-open interval for a character exiting a scene.

  Re-entry left a second open row only if a prior one was closed, so \"most
  recent open\" is unambiguous. A stray exit with no open interval is a no-op
  rather than a corruption.
  """
  def leave(repo, scene_id, character_id, beat) do
    sid = to_string(scene_id)
    cid = to_string(character_id)

    open =
      from(m in __MODULE__,
        where: m.scene_id == ^sid and m.character_id == ^cid and is_nil(m.exited_beat),
        order_by: [desc: m.entered_beat, desc: m.id],
        limit: 1
      )
      |> repo.one()

    case open do
      nil -> :no_open_interval
      row -> repo.update!(Ecto.Changeset.change(row, exited_beat: beat))
    end
  end

  # ── Queries ────────────────────────────────────────────────────────────────

  @doc """
  Is `character_id` a member of `scene_id` at `beat`? Half-open interval
  `[entered_beat, exited_beat)`, matching `MembershipSet.member_at?/4` exactly.
  """
  def member_at?(repo, scene_id, character_id, beat) do
    sid = to_string(scene_id)
    cid = to_string(character_id)

    repo.exists?(
      from(m in __MODULE__,
        where:
          m.scene_id == ^sid and m.character_id == ^cid and
            m.entered_beat <= ^beat and
            (is_nil(m.exited_beat) or m.exited_beat > ^beat)
      )
    )
  end

  @doc "Character ids present at `scene_id` at `beat` (the Director's \"who could walk in\")."
  def members_at(repo, scene_id, beat) do
    sid = to_string(scene_id)

    repo.all(
      from(m in __MODULE__,
        where:
          m.scene_id == ^sid and m.entered_beat <= ^beat and
            (is_nil(m.exited_beat) or m.exited_beat > ^beat),
        select: m.character_id
      )
    )
  end
end
