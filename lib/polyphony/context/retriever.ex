defmodule Polyphony.Context.Retriever do
  @moduledoc """
  The retrieval boundary (§9). Retrieval happens **once, at scene open, against
  the premise** — never per turn against the latest message, which would
  invalidate the prefix every turn and forfeit the ~90% caching discount.

  Two selections, both frozen for the scene:

    * `rank_facts/3` — rank the sheet's long-tail facts against the premise (they
      live on the sheet, so they're passed in and ranked, §6.1).
    * `fetch_summaries/3` — retrieve the character's *own* distant summaries for
      the premise. These live in pgvector (produced by the scene-close pipeline),
      so the retriever fetches them by scope; a caller never hands in another
      viewer's summaries, and the store is character-scoped besides (§8).

  `fetch_summaries/3` returns `[%{scene_id:, text:}]`, ordered most-relevant first.
  """

  @type fact :: Polyphony.Authoring.CharacterSheet.Fact.t()
  @type summary :: %{required(:scene_id) => term(), required(:text) => String.t()}
  @type scope :: %{required(:character_id) => term(), required(:scene_id) => term()}

  @callback rank_facts([fact()], premise :: String.t(), opts :: keyword()) :: [fact()]
  @callback fetch_summaries(scope(), premise :: String.t(), opts :: keyword()) :: [summary()]
end

defmodule Polyphony.Context.StaticRetriever do
  @moduledoc """
  Default retriever with no embeddings: ranks passed-in facts and returns
  whatever summaries the caller supplies via `opts[:summaries]` (or none). Keeps
  the assembler and its tests independent of pgvector; `PgvectorRetriever` is the
  live implementation.
  """
  @behaviour Polyphony.Context.Retriever

  @impl true
  def rank_facts(facts, _premise, opts), do: cap(facts, opts)

  @impl true
  def fetch_summaries(_scope, _premise, opts), do: cap(Keyword.get(opts, :summaries, []), opts)

  defp cap(list, opts) do
    case Keyword.get(opts, :limit) do
      nil -> list
      n -> Enum.take(list, n)
    end
  end
end
