defmodule Polyphony.Embeddings do
  @moduledoc """
  The **metered** entry point for embedding calls (§B5) — the embed-path sibling of
  `Polyphony.LLM.call/2`.

  Every embedding the app produces (scene-close summaries, retrieval query vectors)
  goes through `embed/2` so its cost lands in the ledger. Previously embed calls hit
  the `Embedder` directly and nothing recorded, so embedding spend read zero even
  once real vectors were wired.

  `embed/2` resolves the embedder (same default as before — the mock in dev/test, the
  DeepInfra embedder in prod), calls it, and — on success — records an estimated cost
  attributed to the caller. Recording is **best-effort**: a ledger failure is logged
  and swallowed so accounting can never break a scene close or a retrieval.

  Attribution comes from `opts` (`:user_id` / `:campaign_id`, `:usage_kind` — default
  `"embedding"`); a row is written only when at least one id is present. Cost is
  estimated from the **input** size (~4 chars/token) at the shared configurable rate
  (`config :polyphony, :costs, micro_cents_per_1k_tokens: …`) — embeddings bill on
  input only, and this is an estimate, not a bill.
  """
  require Logger

  alias Polyphony.Costs
  alias Polyphony.SceneClose.Embedder

  @default_rate_per_1k 100

  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    embedder = Keyword.get(opts, :embedder) || Embedder.default()
    result = embedder.embed(text)
    meter(result, text, opts)
    result
  end

  @doc "Rough embedding cost in micro-cents from the input size (~4 chars/token), floored at 1."
  def estimate(text) do
    tokens = div(byte_size(text), 4)
    max(div(tokens * rate_per_1k(), 1000), 1)
  end

  # ── Internals ─────────────────────────────────────────────────────────────────

  defp meter({:ok, _vector}, text, opts) do
    if opts[:user_id] || opts[:campaign_id] do
      Costs.record(%{
        user_id: opts[:user_id],
        campaign_id: opts[:campaign_id],
        amount: estimate(text),
        kind: opts[:usage_kind] || "embedding",
        metadata: %{op: "embedding"}
      })
    end

    :ok
  rescue
    e -> Logger.warning("[usage] embedding not recorded: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end

  defp meter(_error, _text, _opts), do: :ok

  defp rate_per_1k do
    Application.get_env(:polyphony, :costs, [])
    |> Keyword.get(:micro_cents_per_1k_tokens, @default_rate_per_1k)
  end
end
