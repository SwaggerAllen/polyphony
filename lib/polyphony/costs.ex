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
  `allow?/3` before spending, surfacing resume/raise-cap to the user.

  ## The caps are somebody's numbers, not a deploy's

  The error copy has always said *you can raise it in Settings*, and for a long time
  there was nothing in Settings to raise: both ceilings lived in app config, identical
  for everyone. Now a cap resolves **stored → opts → config → default**, so an account
  carries its own daily ceiling and a campaign carries its own lifetime one, and the
  configured value is what a new account starts from rather than what it is stuck with.

  ## They protect against different things

  A **daily** cap protects you from a runaway loop — a stuck Director spending all night.
  A **campaign** cap protects you from one story quietly eating the month. They fail
  differently, so they live in different places: the daily one on the account, the
  lifetime one in campaign settings.
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

  @doc """
  This account's daily ceiling: its own if it has set one, else the configured default.

  A null stored cap is *not* zero — it means "whatever the default is", so raising the
  default reaches every account that never touched theirs.
  """
  @spec daily_cap(map() | nil, keyword()) :: pos_integer()
  def daily_cap(user, opts \\ [])
  def daily_cap(%{daily_cap: cap}, _opts) when is_integer(cap) and cap > 0, do: cap
  def daily_cap(_user, opts), do: cap(:daily_cap, opts)

  @doc """
  The lifetime ceiling on a campaign, from its payload, else the configured default.

  Stored on the campaign rather than the account because it is a fact about the story:
  a long campaign wanting a bigger budget shouldn't have to raise the number that
  protects every *other* story from it.
  """
  @spec campaign_cap(map() | nil, keyword()) :: pos_integer()
  def campaign_cap(payload, opts \\ [])

  def campaign_cap(%{} = payload, opts) do
    case Map.get(payload, :spend_cap) do
      cap when is_integer(cap) and cap > 0 -> cap
      _ -> cap(:campaign_cap, opts)
    end
  end

  def campaign_cap(_payload, opts), do: cap(:campaign_cap, opts)

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
    # Stored first, so the number an author raised in Settings is the number that
    # actually binds — the copy has promised that for a long time.
    daily_cap = Keyword.get(opts, :daily_cap) || daily_cap(stored_user(user_id, opts), opts)

    campaign_cap =
      Keyword.get(opts, :campaign_cap) || campaign_cap(stored_campaign(campaign_id, opts), opts)

    warn_ratio = cap(:warn_ratio, opts)

    # Guard the nil scopes: an unattributed-to-user call (e.g. an org-owned campaign,
    # or scene-close extraction on a campaign with no user owner) has no daily ledger
    # to sum — querying `user_id == nil` is a forbidden nil comparison, and there's
    # nothing to cap anyway.
    daily = if user_id, do: spent_today(user_id, opts), else: 0
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

  @doc """
  Where a user's money went, this calendar month: one row per campaign, biggest first,
  plus everything spent outside any scene.

  Per-campaign spend has never been shown anywhere, which is how a single story can eat
  a month without anyone noticing until the cap bites. `campaign_id: nil` is authoring —
  writing characters and worlds — and it is a real row rather than a rounding error.
  """
  @spec by_campaign(term(), keyword()) :: [map()]
  def by_campaign(user_id, opts \\ []) do
    since = Keyword.get(opts, :since, month_start(now(opts)))

    repo(opts)
    |> Ledger.sum_by_campaign(user_id, since)
    |> Enum.sort_by(&(-&1.amount))
  end

  @doc "Total spend by this user in the current calendar month."
  @spec this_month(term(), keyword()) :: non_neg_integer()
  def this_month(user_id, opts \\ []) do
    Ledger.sum_for_user_since(repo(opts), user_id, month_start(now(opts)))
  end

  @doc """
  Roughly how many more turns today's budget buys — **not** a percentage.

  Nobody knows what 86% of their budget feels like; everybody knows what fourteen more
  turns feels like. Estimated from what this account's recent generations have actually
  cost, so it tracks the models they use rather than a figure from a price list.

  `nil` when there's nothing to estimate from — no history, or no budget left — because
  a made-up number here is worse than an absent one.
  """
  @spec turns_remaining(map() | nil, keyword()) :: pos_integer() | nil
  def turns_remaining(user, opts \\ [])
  def turns_remaining(nil, _opts), do: nil

  def turns_remaining(%{id: id} = user, opts) do
    remaining = daily_cap(user, opts) - spent_today(id, opts)
    average = Ledger.average_generation(repo(opts), id, Keyword.get(opts, :sample, 20))

    if remaining > 0 and is_integer(average) and average > 0,
      do: max(div(remaining, average), 1),
      else: nil
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

  # Read through rather than passed in, so every call site gets the account's own
  # ceiling without threading it — including the ones deep in the generation path that
  # only know a user id.
  defp stored_user(nil, _opts), do: nil

  defp stored_user(user_id, opts) do
    Polyphony.Accounts.get(user_id, opts)
  rescue
    _ -> nil
  end

  defp stored_campaign(nil, _opts), do: nil

  defp stored_campaign(campaign_id, opts) do
    case Polyphony.Library.get(campaign_id, opts) do
      nil -> nil
      entry -> Polyphony.Library.payload(entry)
    end
  rescue
    _ -> nil
  end

  defp cap(key, opts) do
    Keyword.get(opts, key) ||
      config()[key] ||
      Keyword.fetch!(@defaults, key)
  end

  defp config, do: Application.get_env(:polyphony, :costs, [])

  # A calendar month, not a rolling 30 days — "this month" on the screen means what the
  # reader's calendar says, and a rolling window would make the total drift downward
  # while they watched it.
  defp month_start(now), do: %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp now(opts),
    do:
      Keyword.get_lazy(opts, :now, fn ->
        NaiveDateTime.truncate(NaiveDateTime.utc_now(), :microsecond)
      end)
end
