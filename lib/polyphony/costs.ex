defmodule Polyphony.Costs do
  @moduledoc """
  Spend accounting + the generation circuit breaker (§B5).

  The brief's cost model is per-campaign; this adds **per-user** accounting too, both
  for the dashboard breakdown and to be billing-ready. On top of the append-only
  `Ledger`, two ceilings guard the fan-out + recursion + cheap-re-roll spend profile —
  a stuck Director loop must not run unbounded:

    * a **per-day** cap (rolling 24h, per user), and
    * a **per-campaign** cap (lifetime).

  `check/3` returns `:ok`, `{:warn, info}` at the soft threshold, or `{:stop, info}`
  once either ceiling is crossed — the **hard stop** the generation path consults via
  `allow?/3` before spending, surfacing resume/raise-cap to the user. Caps come from
  opts, else app config, else the module defaults.
  """

  alias Polyphony.Repo
  alias Polyphony.Costs.Ledger

  @day_seconds 24 * 60 * 60
  @defaults [daily_cap: 1_000_000, campaign_cap: 5_000_000, warn_ratio: 0.8]

  @doc "Record a billable event. `attrs`: `:user_id`, `:campaign_id`, `:amount`, `:kind`."
  def record(attrs, opts \\ []) do
    attrs = Map.new(attrs)

    Ledger.put(repo(opts), %{
      user_id: Map.get(attrs, :user_id),
      campaign_id: Map.get(attrs, :campaign_id) && to_string(Map.get(attrs, :campaign_id)),
      amount: Map.get(attrs, :amount, 0),
      kind: to_string(Map.get(attrs, :kind, "generation")),
      metadata: Map.get(attrs, :metadata, %{})
    })
  end

  @doc "Rolling per-day (24h) spend for a user."
  def spent_today(user_id, opts \\ []) do
    since = NaiveDateTime.add(now(opts), -@day_seconds)
    Ledger.sum_for_user_since(repo(opts), user_id, since)
  end

  @doc "Lifetime spend on a campaign."
  def spent_campaign(campaign_id, opts \\ []),
    do: Ledger.sum_for_campaign(repo(opts), campaign_id)

  @doc """
  Evaluate both ceilings for `user_id` on `campaign_id`. Returns `:ok`, `{:warn,
  info}` at the soft threshold, or `{:stop, info}` past a cap. `info` carries the
  binding `:scope` (`:daily` | `:campaign`), the `:spent`, and the `:cap`.
  """
  @spec check(term(), term(), keyword()) :: :ok | {:warn, map()} | {:stop, map()}
  def check(user_id, campaign_id, opts \\ []) do
    daily_cap = cap(:daily_cap, opts)
    campaign_cap = cap(:campaign_cap, opts)
    warn_ratio = cap(:warn_ratio, opts)

    daily = spent_today(user_id, opts)
    campaign = if campaign_id, do: spent_campaign(campaign_id, opts), else: 0

    verdicts = [
      verdict(:daily, daily, daily_cap, warn_ratio),
      verdict(:campaign, campaign, campaign_cap, warn_ratio)
    ]

    # A stop on either scope wins; else a warn on either; else ok. The binding scope
    # is the tightest one — the reason surfaced to the user.
    cond do
      stop = Enum.find(verdicts, &match?({:stop, _}, &1)) -> stop
      warn = Enum.find(verdicts, &match?({:warn, _}, &1)) -> warn
      true -> :ok
    end
  end

  @doc "The circuit breaker: may generation proceed? False once a hard stop is hit."
  @spec allow?(term(), term(), keyword()) :: boolean()
  def allow?(user_id, campaign_id, opts \\ []),
    do: not match?({:stop, _}, check(user_id, campaign_id, opts))

  # ── Internals ─────────────────────────────────────────────────────────────────

  defp verdict(scope, spent, cap, warn_ratio) do
    cond do
      spent >= cap -> {:stop, %{scope: scope, spent: spent, cap: cap}}
      spent >= cap * warn_ratio -> {:warn, %{scope: scope, spent: spent, cap: cap}}
      true -> :ok
    end
  end

  defp cap(key, opts) do
    Keyword.get(opts, key) ||
      config()[key] ||
      Keyword.fetch!(@defaults, key)
  end

  defp config, do: Application.get_env(:polyphony, :costs, [])

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      end)
end
