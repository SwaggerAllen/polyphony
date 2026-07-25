defmodule Polyphony.CostsTest do
  @moduledoc """
  §B5: spend accounting + the circuit breaker. Tested hardest is the hard stop — once
  a per-day or per-campaign ceiling is crossed, generation is paused (`allow?/3`
  false) — plus the soft-warning threshold and the rolling day window.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Costs, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  @caps [daily_cap: 100, campaign_cap: 1000, warn_ratio: 0.8]

  defp spend(amount, opts \\ []) do
    Costs.record(
      Map.merge(
        %{user_id: 1, campaign_id: "camp", amount: amount, kind: "generation"},
        Map.new(opts)
      )
    )
  end

  describe "accounting" do
    test "per-user rolling-day and per-campaign sums" do
      spend(30)
      spend(20, user_id: 1, campaign_id: "camp")
      assert Costs.spent_today(1) == 50
      assert Costs.spent_campaign("camp") == 50
    end

    test "spend outside the 24h window is excluded from the daily total" do
      # Record an old entry by inserting it directly with a stale timestamp.
      old =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-2 * 24 * 60 * 60)
        |> NaiveDateTime.truncate(:microsecond)

      Repo.insert!(%Polyphony.Costs.Ledger{
        user_id: 1,
        campaign_id: "camp",
        amount: 40,
        kind: "generation",
        inserted_at: old
      })

      spend(10)

      assert Costs.spent_today(1) == 10
      # Campaign total is lifetime, so it still counts the old spend.
      assert Costs.spent_campaign("camp") == 50
    end
  end

  describe "the circuit breaker" do
    test "under threshold is :ok and allowed" do
      spend(50)
      assert Costs.check(1, "camp", @caps) == :ok
      assert Costs.allow?(1, "camp", @caps)
    end

    test "at the soft threshold warns but still allows" do
      spend(85)
      assert {:warn, %{scope: :daily, cap: 100}} = Costs.check(1, "camp", @caps)
      assert Costs.allow?(1, "camp", @caps)
    end

    test "past the daily cap hard-stops and pauses generation" do
      spend(100)
      assert {:stop, %{scope: :daily, spent: 100, cap: 100}} = Costs.check(1, "camp", @caps)
      refute Costs.allow?(1, "camp", @caps)
    end

    test "the per-campaign ceiling stops even when the daily one is fine" do
      # One big campaign spend by another user keeps this user's daily total low.
      spend(1000, user_id: 2)
      assert Costs.spent_today(1, @caps) == 0
      assert {:stop, %{scope: :campaign, cap: 1000}} = Costs.check(1, "camp", @caps)
      refute Costs.allow?(1, "camp", @caps)
    end

    test "a stop on either scope wins over a warn on the other" do
      spend(100)
      # daily is at cap (stop); campaign is 100 (ok) — stop must win.
      assert {:stop, %{scope: :daily}} = Costs.check(1, "camp", @caps)
    end
  end
end
