defmodule Polyphony.ReadModels.SceneSummary do
  @moduledoc """
  Per-character scene summaries with embeddings (§8).

  Keyed by `character_id` — `"omniscient"` for the user's table-of-contents
  summary, a character id for each participant's *filtered* summary. `search/4`
  scopes by `character_id` in the query itself, so a character can only ever
  retrieve their own summaries: the anti-leak guard is structural, not a `WHERE`
  clause a caller might forget.
  """
  use Ecto.Schema
  import Ecto.Query
  import Pgvector.Ecto.Query

  @omniscient "omniscient"

  schema "character_scene_summaries" do
    field(:scene_id, :string)
    field(:character_id, :string)
    field(:summary, :string)
    field(:embedding, Pgvector.Ecto.Vector)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "The reserved viewer key for the omniscient (user / table-of-contents) summary."
  def omniscient_key, do: @omniscient

  @doc "Upsert a summary for `(scene_id, character_id)`."
  def put(repo, scene_id, character_id, summary, embedding) do
    repo.insert!(
      %__MODULE__{
        scene_id: to_string(scene_id),
        character_id: to_string(character_id),
        summary: summary,
        embedding: embedding
      },
      on_conflict: {:replace, [:summary, :embedding, :updated_at]},
      conflict_target: [:scene_id, :character_id]
    )
  end

  @doc """
  The scenes this character has **closed**, oldest first — the stops on the sheet
  scrubber (§2.14).

  A summary row is written at scene close and only then, so the existence of one is
  what "this scene is finished" means here. That is also the right resolution for
  the scrubber: arc is extracted at close, so there is nothing to wind back to
  between two closes.

  Returns `[%{scene_id: id, summary: text, closed_at: naive_datetime}]`. The
  character's *own* filtered summary, never the omniscient one — the scrubber shows
  a sheet as it stood, and the sheet is theirs.
  """
  def closed_scenes_for(repo, character_id) do
    cid = to_string(character_id)

    repo.all(
      from(s in __MODULE__,
        where: s.character_id == ^cid,
        order_by: [asc: s.inserted_at, asc: s.id],
        select: %{scene_id: s.scene_id, summary: s.summary, closed_at: s.inserted_at}
      )
    )
  end

  @doc """
  The `limit` summaries closest to `query_embedding` **within `character_id`'s own
  summaries** — the memory-gradient retrieval slice 4 consumes (§9), scoped so it
  can never surface another viewer's summary.
  """
  def search(repo, character_id, query_embedding, limit \\ 5) do
    cid = to_string(character_id)
    vec = Pgvector.new(query_embedding)

    repo.all(
      from(s in __MODULE__,
        where: s.character_id == ^cid,
        order_by: cosine_distance(s.embedding, ^vec),
        limit: ^limit
      )
    )
  end
end
