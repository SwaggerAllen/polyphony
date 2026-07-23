defmodule Polyphony.Context.Retriever do
  @moduledoc """
  The retrieval boundary (§9). Retrieval happens **once, at scene open, against
  the premise** — never per turn against the latest message, which would
  invalidate the prefix every turn and forfeit the ~90% caching discount.

  Two ranked selections, both frozen for the scene:

    * long-tail facts vs. the scene premise (pgvector, §6.1);
    * the character's *own* distant summaries vs. the premise (§8 — never the
      omniscient summary, or withheld information leaks back in prose form).

  Real ranking is pgvector cosine distance; this behaviour keeps that behind an
  interface so the assembler and its tests don't depend on embeddings.
  """

  @type fact :: Polyphony.Authoring.CharacterSheet.Fact.t()
  @type summary :: %{required(:scene_id) => term(), required(:text) => String.t()}

  @callback rank_facts([fact()], premise :: String.t(), opts :: keyword()) :: [fact()]
  @callback rank_summaries([summary()], premise :: String.t(), opts :: keyword()) :: [summary()]
end

defmodule Polyphony.Context.StaticRetriever do
  @moduledoc """
  Default retriever with no embeddings: returns the candidates in order, capped
  by `:limit`. Sufficient for wiring and tests; the pgvector-backed retriever
  swaps in behind the same behaviour once embeddings exist (slice 7).
  """
  @behaviour Polyphony.Context.Retriever

  @impl true
  def rank_facts(facts, _premise, opts), do: cap(facts, opts)

  @impl true
  def rank_summaries(summaries, _premise, opts), do: cap(summaries, opts)

  defp cap(list, opts) do
    case Keyword.get(opts, :limit) do
      nil -> list
      n -> Enum.take(list, n)
    end
  end
end
