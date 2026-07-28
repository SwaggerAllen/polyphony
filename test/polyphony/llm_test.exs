defmodule Polyphony.LLMTest do
  @moduledoc """
  The metered LLM entry point (§B5): every call books estimated usage into the cost
  ledger when attributed, records nothing when unattributed or on error, and never
  lets a ledger failure break the call.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{LLM, Costs, Repo}
  alias Polyphony.Costs.Ledger

  @stub Polyphony.LLM.Stub
  @messages [%{role: "user", content: "hello there, tell me a story"}]

  defmodule EchoModel do
    @behaviour Polyphony.LLM.Provider
    @impl true
    def complete(_messages, opts), do: {:ok, to_string(Keyword.get(opts, :model))}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "records estimated usage to the ledger for an attributed call" do
    assert {:ok, "a response"} =
             LLM.call(@messages,
               provider: @stub,
               respond_with: {:ok, "a response"},
               user_id: 42,
               usage_kind: "authoring"
             )

    assert Costs.spent_today(42) > 0
    assert [%Ledger{kind: "authoring", user_id: 42}] = Repo.all(Ledger)
  end

  test "writes nothing when the call is unattributed" do
    assert {:ok, "x"} = LLM.call(@messages, provider: @stub, respond_with: {:ok, "x"})
    assert Repo.aggregate(Ledger, :count) == 0
  end

  test "writes nothing when the provider errors" do
    assert {:error, :boom} =
             LLM.call(@messages, provider: @stub, respond_with: {:error, :boom}, user_id: 7)

    assert Costs.spent_today(7) == 0
  end

  test "estimate grows with prompt + response size" do
    small = LLM.estimate([%{role: "user", content: "hi"}], "ok")
    big = LLM.estimate([%{role: "user", content: String.duplicate("word ", 500)}], "reply")
    assert big > small
  end

  test "Autofill forwards user attribution so authoring generation is metered" do
    alias Polyphony.Authoring.Autofill

    assert {:ok, _values} =
             Autofill.generate_all(:world_bible, "a drowned city", %{},
               provider: Polyphony.LLM.Mock,
               user_id: 99,
               usage_kind: "authoring"
             )

    assert Costs.spent_today(99) > 0
  end

  describe "circuit breaker (§B5)" do
    test "refuses an attributed call once a hard cap is hit — and doesn't spend" do
      # Blow past the default per-day cap (1_000_000) for this user.
      Costs.record(%{user_id: 5, amount: 2_000_000, kind: "generation"})

      assert {:error, :cost_cap_reached} =
               LLM.call(@messages, provider: @stub, respond_with: {:ok, "x"}, user_id: 5)

      # No new ledger row — the provider was never called, nothing metered.
      assert Repo.aggregate(Ledger, :count) == 1
    end

    test "an unattributed call is never gated (no ledger to check)" do
      Costs.record(%{user_id: 6, amount: 2_000_000, kind: "generation"})
      # No user_id/campaign_id on this call, so the breaker can't and doesn't apply.
      assert {:ok, "x"} = LLM.call(@messages, provider: @stub, respond_with: {:ok, "x"})
    end
  end

  describe "force-heavy debug lever" do
    test "routes every call to the heavy model when enabled" do
      # Self-contained config so the test doesn't depend on whatever :llm another test
      # left in the shared app env (some replace it with just a provider).
      prev_llm = Application.get_env(:polyphony, :llm)
      prev_flag = Application.get_env(:polyphony, :force_heavy_model)

      Application.put_env(:polyphony, :llm, models: %{workhorse: "WORK", heavy: "HEAVY-MODEL"})
      Application.put_env(:polyphony, :force_heavy_model, true)

      on_exit(fn ->
        Application.put_env(:polyphony, :llm, prev_llm)
        Application.put_env(:polyphony, :force_heavy_model, prev_flag)
      end)

      # The caller asked for a different model; the lever overrides it to heavy.
      assert {:ok, "HEAVY-MODEL"} = LLM.call(@messages, provider: EchoModel, model: "workhorse-xyz")
    end
  end
end
