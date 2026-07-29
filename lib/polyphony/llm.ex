defmodule Polyphony.LLM do
  @moduledoc """
  The **metered** entry point for provider calls. Every LLM call in the app goes
  through `call/2` so its usage lands in the cost ledger (§B5) — the single seam that
  keeps the usage dashboard and the circuit breaker honest. Previously call sites hit
  `Provider.complete/2` directly and nothing recorded, so usage always read zero.

  `call/2` is a thin wrapper: it resolves the provider (same default as before),
  makes the call, and — on success — records an estimated cost attributed to the
  caller. Recording is **best-effort**: a ledger failure is logged and swallowed so
  accounting can never break generation.

  Attribution comes from `opts`:

    * `:user_id` / `:campaign_id` — who to bill; a row is only written when at least
      one is present (so un-attributed internal calls don't clutter the ledger).
    * `:usage_kind` — the ledger `kind` (default `"generation"`).

  Cost is **estimated** from prompt + response size (~4 chars/token) at a configurable
  rate (`config :polyphony, :costs, micro_cents_per_1k_tokens: …`). It's an estimate,
  not a bill — good enough for the dashboard and the caps until the provider returns
  real token counts.
  """
  require Logger

  alias Polyphony.{Costs, DebugFlags, DebugTap}
  alias Polyphony.LLM.Provider

  @default_rate_per_1k 100

  @spec call([Provider.message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def call(messages, opts \\ []) do
    opts = maybe_force_heavy(opts)

    if allowed?(opts) do
      provider = Keyword.get(opts, :provider) || Provider.default()
      result = provider.complete(messages, opts)
      meter(result, messages, opts)
      trace(messages, result, opts)
      result
    else
      # Circuit breaker (§B5): an attributed caller over a hard cap doesn't spend.
      {:error, :cost_cap_reached}
    end
  end

  # The circuit breaker: refuse an attributed call once a hard cap is hit, so a stuck
  # Director loop (or heavy-model testing) can't run unbounded. Unattributed internal
  # calls have no per-user/campaign ledger to check, so they pass.
  defp allowed?(opts) do
    case {opts[:user_id], opts[:campaign_id]} do
      {nil, nil} -> true
      {user_id, campaign_id} -> Costs.allow?(user_id, campaign_id)
    end
  end

  # Debug lever: when `:force_heavy_model` is set (toggled from the debug drawer),
  # route every chat call to the heavy model regardless of the caller's choice — for
  # eyeballing heavy-model quality without editing config.
  defp maybe_force_heavy(opts) do
    if Application.get_env(:polyphony, :force_heavy_model, false) do
      Keyword.put(opts, :model, heavy_model())
    else
      opts
    end
  end

  defp heavy_model, do: get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])

  @doc """
  Rough cost estimate in micro-cents from prompt + response size (~4 chars/token).
  Floored at 1 so every real call registers, even a tiny one (integer division
  would otherwise round short calls to zero and they'd never show up).
  """
  def estimate(messages, text) do
    tokens = div(message_bytes(messages) + byte_size(text), 4)
    max(div(tokens * rate_per_1k(), 1000), 1)
  end

  # ── Internals ─────────────────────────────────────────────────────────────────

  defp meter({:ok, text}, messages, opts) do
    record(estimate(messages, text), opts)
  rescue
    e -> Logger.warning("[usage] not recorded: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end

  defp meter(_error, _messages, _opts), do: :ok

  # Debug capture (bring-up): the actual request + response for a scene generation, when
  # the :trace flag is on. Best-effort; only scene-scoped calls (they carry :scene_id).
  defp trace(messages, result, opts) do
    if opts[:scene_id] && DebugFlags.get(:trace) do
      DebugTap.record(%{
        scene_id: opts[:scene_id],
        subject: opts[:debug_subject] || opts[:usage_kind] || "generation",
        params: Keyword.take(opts, [:model, :thinking, :max_tokens, :response, :usage_kind]),
        request: messages,
        response: result
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp record(amount, opts) do
    if opts[:user_id] || opts[:campaign_id] do
      Costs.record(%{
        user_id: opts[:user_id],
        campaign_id: opts[:campaign_id],
        amount: amount,
        kind: opts[:usage_kind] || "generation",
        metadata: %{model: opts[:model], response: opts[:response]}
      })
    end

    :ok
  end

  defp message_bytes(messages) do
    Enum.reduce(messages, 0, fn m, acc ->
      acc + byte_size(to_string(m[:content] || m["content"] || ""))
    end)
  end

  defp rate_per_1k do
    Application.get_env(:polyphony, :costs, [])
    |> Keyword.get(:micro_cents_per_1k_tokens, @default_rate_per_1k)
  end
end
