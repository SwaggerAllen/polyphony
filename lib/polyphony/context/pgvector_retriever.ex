defmodule Polyphony.Context.PgvectorRetriever do
  @moduledoc """
  The live retriever (§8, §9): fetches a character's distant summaries from
  pgvector by embedding the scene premise and searching **that character's own**
  summaries.

  This closes the memory gradient — the scene-close pipeline writes per-character
  summaries (`ReadModels.SceneSummary`), and this reads them back at scene open,
  scoped so a character can only ever retrieve their own. Facts are still ranked
  in-memory (they live on the sheet, not in pgvector yet).

  Options: `:repo`, `:embedder`, `:limit`. Falls back gracefully (returns `[]`)
  if retrieval errors — a missing summary is survivable (§12), and the verbatim
  recent scene covers recent memory anyway.
  """
  @behaviour Polyphony.Context.Retriever

  require Logger

  alias Polyphony.Repo
  alias Polyphony.ReadModels.SceneSummary
  alias Polyphony.SceneClose.Embedder

  @impl true
  def rank_facts(facts, _premise, opts) do
    case Keyword.get(opts, :limit) do
      nil -> facts
      n -> Enum.take(facts, n)
    end
  end

  @impl true
  def fetch_summaries(%{character_id: character_id}, premise, opts) do
    repo = Keyword.get(opts, :repo) || Repo
    embedder = Keyword.get(opts, :embedder) || Embedder.default()
    limit = Keyword.get(opts, :limit) || 5

    with {:ok, embedding} <- embedder.embed(premise || "") do
      repo
      |> SceneSummary.search(character_id, embedding, limit)
      |> Enum.map(&%{scene_id: &1.scene_id, text: &1.summary})
    else
      _ -> []
    end
  rescue
    e ->
      Logger.warning("summary retrieval failed for #{inspect(character_id)}: #{inspect(e)}")
      []
  end
end
