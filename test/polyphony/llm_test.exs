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
end
