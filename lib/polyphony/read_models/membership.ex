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

  @doc """
  Everyone who was ever in `scene_id` — the cast a *whoever was there* audience means.

  Ever, not at a beat: someone who walked in for the last two beats was there when it
  happened, and the audience is about having been present at all.
  """
  def all_members(repo, scene_id) do
    sid = to_string(scene_id)

    repo.all(
      from(m in __MODULE__,
        where: m.scene_id == ^sid,
        group_by: m.character_id,
        order_by: [asc: min(m.entered_beat)],
        select: m.character_id
      )
    )
  end

  @doc """
  The scenes a character has ever been in, distinct and in first-entry order.

  Distinct because re-entry opens a second interval: someone who leaves a scene and
  comes back is in *one* scene, and "In 3 scenes" on their sheet must not count the
  door twice. Ordered by when they first entered each, which is the only ordering
  the membership table itself knows — for a chronology of *closed* scenes, ask
  `SceneSummary`, which is written at scene close.
  """
  def scenes_for_character(repo, character_id) do
    cid = to_string(character_id)

    repo.all(
      from(m in __MODULE__,
        where: m.character_id == ^cid,
        group_by: m.scene_id,
        order_by: [asc: min(m.entered_beat), asc: m.scene_id],
        select: m.scene_id
      )
    )
  end

  @doc "How many distinct scenes a character has been in (\"In 3 scenes\")."
  def scene_count(repo, character_id), do: repo |> scenes_for_character(character_id) |> length()
end
