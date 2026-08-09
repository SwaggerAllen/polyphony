defmodule Polyphony.ReadModels.ArcEntry do
  @moduledoc """
  The proposed-arc-entry authoring table (§6.2, §9, §2.8).

  Arc entries are interpreted, campaign-scoped, and need a review gate — so they
  live in an authoring table, not the effective sheet/bible. Everything lands
  `:proposed`; `accept/2` promotes to `:canon` (and only canon feeds the effective
  sheet or world bible), `reject/2` retracts, `edit/3` corrects a proposal.

  One table, two subjects (`subject_type`): **character** arc (`subject_id` = a
  character id, feeds `EffectiveSheet`) and **world** arc (`subject_id` = the
  campaign id, `scope`/`location_id` set, feeds `EffectiveWorldBible`).
  """
  use Ecto.Schema
  import Ecto.Query

  alias Polyphony.Authoring.ArcEntry, as: Domain
  alias PolyphonyCore.Blob
  alias Polyphony.Authoring.WorldArcEntry
  @typedoc "A row of this table. `Ecto.Schema` generates no `t/0`, so it is declared here."
  @type t :: %__MODULE__{}

  schema "arc_entries" do
    field(:subject_id, :string)
    field(:subject_type, :string, default: "character")
    field(:kind, :string)
    field(:sheet_field, :string)
    field(:statement, :string)
    # The "Because" line every proposal carries (`ux/polyphony-arc.html` §02).
    field(:reason, :string)
    # `:release` only — which line gave.
    field(:released_topic, :string)
    field(:status, :string, default: "proposed")
    field(:promotable, :boolean, default: true)
    field(:beat, :integer)
    field(:source_scene_id, :string)
    # World arc only (null for character rows):
    field(:scope, :string)
    field(:location_id, :string)
    field(:concealed, :boolean, default: false)
    # Encoded `Polyphony.Authoring.Audience` — who starts out knowing a world fact.
    field(:audience, :binary)
    # Authored entries (STR-62). All nil on an extracted proposal.
    field(:author, :string)
    field(:operation, :string)
    field(:timing, :string)
    field(:replaces, :string)
    field(:direction, :string)
    field(:line_condition, :string)
    field(:after_release, :string)
    # Release proposals: false means the Director proposed past the written condition.
    field(:condition_met, :boolean)
    field(:core, :boolean)
    field(:target, :string)
    field(:target_id, :string)
    timestamps(type: :naive_datetime_usec)
  end

  # ── Writes ───────────────────────────────────────────────────────────────────

  @doc "Persist a domain `ArcEntry` proposal for a character `subject_id`."
  def put(repo, %Domain{} = entry, subject_id) do
    repo.insert!(%__MODULE__{
      subject_id: to_string(subject_id),
      subject_type: "character",
      kind: to_string(entry.kind),
      sheet_field: entry.sheet_field,
      statement: entry.statement,
      reason: entry.reason,
      released_topic: entry.released_topic,
      status: to_string(entry.status || :proposed),
      promotable: entry.promotable,
      beat: entry.beat,
      source_scene_id: entry.source_scene_id && to_string(entry.source_scene_id),
      concealed: entry.concealed || false,
      audience: entry.audience && Blob.encode(entry.audience),
      author: entry.author,
      operation: entry.operation && to_string(entry.operation),
      timing: entry.timing && to_string(entry.timing),
      replaces: entry.replaces,
      direction: entry.direction && to_string(entry.direction),
      line_condition: entry.line_condition,
      after_release: entry.after_release,
      condition_met: entry.condition_met,
      core: entry.core,
      target: entry.target,
      target_id: entry.target_id && to_string(entry.target_id)
    })
  end

  @doc "Persist a domain `WorldArcEntry` proposal for a campaign (`subject_id` = campaign id)."
  def put_world(repo, %WorldArcEntry{} = entry, campaign_id) do
    repo.insert!(%__MODULE__{
      subject_id: to_string(campaign_id),
      subject_type: "world",
      kind: to_string(entry.kind),
      sheet_field: entry.sheet_field,
      statement: entry.statement,
      reason: entry.reason,
      status: to_string(entry.status || :proposed),
      promotable: entry.promotable,
      beat: entry.beat,
      source_scene_id: entry.source_scene_id && to_string(entry.source_scene_id),
      scope: to_string(entry.scope || :global),
      location_id: entry.location_id && to_string(entry.location_id),
      concealed: entry.concealed,
      audience: Blob.encode(entry.audience),
      author: entry.author,
      operation: entry.operation && to_string(entry.operation),
      timing: entry.timing && to_string(entry.timing),
      replaces: entry.replaces
    })
  end

  # ── Reads: proposed rows (for the review UI) ─────────────────────────────────

  @doc "Proposed entries awaiting review for a subject (character by default)."
  def list_proposed(repo, subject_id, subject_type \\ "character") do
    sid = to_string(subject_id)

    repo.all(
      from(a in __MODULE__,
        where:
          a.subject_id == ^sid and a.subject_type == ^subject_type and a.status == "proposed",
        order_by: [asc: a.inserted_at]
      )
    )
  end

  @doc "Proposed **world** arc awaiting review for a campaign."
  def list_proposed_world(repo, campaign_id), do: list_proposed(repo, campaign_id, "world")

  @doc """
  Pending-proposal counts for many characters at once — what the Set-the-scene cast
  rows read (STR-62). Returns `%{subject_id => count}`; a subject with nothing
  pending is absent.
  """
  @spec proposed_counts(Ecto.Repo.t(), [term()]) :: %{String.t() => non_neg_integer()}
  def proposed_counts(repo, subject_ids) do
    sids = subject_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    repo.all(
      from(a in __MODULE__,
        where: a.subject_id in ^sids and a.subject_type == "character" and a.status == "proposed",
        group_by: a.subject_id,
        select: {a.subject_id, count(a.id)}
      )
    )
    |> Map.new()
  end

  # ── Reads: canon as domain structs (for the effective fold) ──────────────────

  @doc "Canon **character** arc for a character, as domain `ArcEntry` structs (feeds `EffectiveSheet`)."
  def canon_for_character(repo, character_id) do
    repo
    |> canon_rows(character_id, "character")
    |> Enum.map(&to_char_domain/1)
  end

  @doc "Canon **world** arc for a campaign, as domain `WorldArcEntry` structs (feeds `EffectiveWorldBible`)."
  def canon_for_world(repo, campaign_id) do
    repo
    |> canon_rows(campaign_id, "world")
    |> Enum.map(&to_world_domain/1)
  end

  defp canon_rows(repo, subject_id, subject_type) do
    sid = to_string(subject_id)

    repo.all(
      from(a in __MODULE__,
        where: a.subject_id == ^sid and a.subject_type == ^subject_type and a.status == "canon"
      )
    )
  end

  # ── Review gate transitions ──────────────────────────────────────────────────

  @doc "Promote a proposed entry to canon (the review gate's accept)."
  def accept(repo, id), do: set_status(repo, id, "canon")

  @doc """
  Accept every proposal for a subject at once — the *Accept all N* the design calls
  the intended fast path, and the only one.

  The gate exists to keep state consistent, not to force careful reading: one tap is
  already as cheap as an escape hatch gets, which is why there isn't a second one.
  Returns how many were promoted.
  """
  @spec accept_all(Ecto.Repo.t(), term(), String.t()) :: non_neg_integer()
  def accept_all(repo, subject_id, subject_type \\ "character") do
    sid = to_string(subject_id)

    {count, _} =
      repo.update_all(
        from(a in __MODULE__,
          where:
            a.subject_id == ^sid and a.subject_type == ^subject_type and a.status == "proposed"
        ),
        set: [status: "canon"]
      )

    count
  end

  @doc "Retract a proposed entry (review's reject) — it never reaches canon."
  def reject(repo, id), do: set_status(repo, id, "retracted")

  @doc """
  Accept a world fact proposed as common knowledge, narrowed to **only who was
  there** (STR-62). The refusal narrows the audience rather than rejecting the
  fact — the thing is true either way and the question is who it reached. The
  entry goes canon concealed, with a `scene: true` audience that resolves to the
  cast of its source scene.
  """
  def accept_narrowed(repo, id) do
    repo.get!(__MODULE__, id)
    |> Ecto.Changeset.change(
      status: "canon",
      concealed: true,
      audience: Blob.encode(%Polyphony.Authoring.Audience{scene: true})
    )
    |> repo.update!()
  end

  @doc """
  Take back something already accepted.

  A real action rather than accept-or-reject at review time only: something you
  accepted in March can turn out wrong in June (`ux/polyphony-arc.html` §04). The same
  transition as a reject — canon stops being canon — which is why it's the same write.
  """
  def retract(repo, id), do: set_status(repo, id, "retracted")

  @doc "Canon entries for a subject, newest last — what a sheet's provenance reads."
  def list_canon(repo, subject_id, subject_type \\ "character") do
    sid = to_string(subject_id)

    repo.all(
      from(a in __MODULE__,
        where: a.subject_id == ^sid and a.subject_type == ^subject_type and a.status == "canon",
        order_by: [asc: a.inserted_at]
      )
    )
  end

  @doc "Correct a proposal before review (statement, and for world arc `scope`)."
  def edit(repo, id, attrs) do
    changes =
      attrs
      |> Map.take([:statement, :scope])
      |> Map.new(fn {k, v} -> {k, v && to_string(v)} end)

    repo.get!(__MODULE__, id)
    |> Ecto.Changeset.change(changes)
    |> repo.update!()
  end

  @doc """
  Re-file a row under a different subject type.

  Groups file their own arc under `"group"` (`Authoring.GroupArc`), and `put/3` writes
  characters — so the fan-out corrects it here rather than duplicating the whole insert
  for one column.
  """
  def set_subject_type(repo, id, subject_type) do
    repo.get!(__MODULE__, id)
    |> Ecto.Changeset.change(subject_type: to_string(subject_type))
    |> repo.update!()
  end

  defp set_status(repo, id, status) do
    repo.get!(__MODULE__, id)
    |> Ecto.Changeset.change(status: status)
    |> repo.update!()
  end

  # ── Row → domain ─────────────────────────────────────────────────────────────

  defp to_char_domain(row) do
    %Domain{
      kind: safe_atom(row.kind),
      sheet_field: row.sheet_field,
      statement: row.statement,
      reason: row.reason,
      released_topic: row.released_topic,
      beat: row.beat,
      source_scene_id: row.source_scene_id,
      status: safe_atom(row.status),
      promotable: row.promotable,
      concealed: row.concealed || false,
      audience: decode_audience(row.audience),
      author: row.author,
      operation: safe_atom(row.operation),
      timing: safe_atom(row.timing),
      replaces: row.replaces,
      direction: safe_atom(row.direction),
      line_condition: row.line_condition,
      after_release: row.after_release,
      condition_met: row.condition_met,
      core: row.core,
      target: row.target,
      target_id: row.target_id
    }
  end

  defp to_world_domain(row) do
    %WorldArcEntry{
      kind: safe_atom(row.kind),
      sheet_field: row.sheet_field,
      statement: row.statement,
      reason: row.reason,
      scope: safe_atom(row.scope || "global"),
      location_id: row.location_id,
      concealed: row.concealed,
      audience: decode_audience(row.audience),
      beat: row.beat,
      source_scene_id: row.source_scene_id,
      status: safe_atom(row.status),
      promotable: row.promotable,
      author: row.author,
      operation: safe_atom(row.operation),
      timing: safe_atom(row.timing),
      replaces: row.replaces
    }
  end

  defp decode_audience(bin), do: Blob.decode(bin)

  defp safe_atom(nil), do: nil
  defp safe_atom(s), do: String.to_existing_atom(s)
end
