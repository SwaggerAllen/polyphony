defmodule Polyphony.ReadModels.ArcEntry do
  @moduledoc """
  The proposed-arc-entry authoring table (§6.2, §9).

  Arc entries are interpreted, campaign-scoped, and need a review gate — so they
  live in an authoring table, not the effective sheet. Everything lands
  `:proposed`; `accept/2` promotes to `:canon`, and only canon entries feed
  `Polyphony.Authoring.EffectiveSheet`.
  """
  use Ecto.Schema
  import Ecto.Query

  alias Polyphony.Authoring.ArcEntry, as: Domain

  schema "arc_entries" do
    field(:subject_id, :string)
    field(:subject_type, :string, default: "character")
    field(:kind, :string)
    field(:sheet_field, :string)
    field(:statement, :string)
    field(:status, :string, default: "proposed")
    field(:promotable, :boolean, default: true)
    field(:beat, :integer)
    field(:source_scene_id, :string)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "Persist a domain `ArcEntry` proposal for `subject_id`."
  def put(repo, %Domain{} = entry, subject_id) do
    repo.insert!(%__MODULE__{
      subject_id: to_string(subject_id),
      subject_type: "character",
      kind: to_string(entry.kind),
      sheet_field: entry.sheet_field,
      statement: entry.statement,
      status: to_string(entry.status || :proposed),
      promotable: entry.promotable,
      beat: entry.beat,
      source_scene_id: entry.source_scene_id && to_string(entry.source_scene_id)
    })
  end

  @doc "Proposed entries awaiting review for a subject."
  def list_proposed(repo, subject_id) do
    cid = to_string(subject_id)
    repo.all(from(a in __MODULE__, where: a.subject_id == ^cid and a.status == "proposed"))
  end

  @doc "Promote a proposed entry to canon (the review gate's accept)."
  def accept(repo, id) do
    repo.get!(__MODULE__, id)
    |> Ecto.Changeset.change(status: "canon")
    |> repo.update!()
  end
end
