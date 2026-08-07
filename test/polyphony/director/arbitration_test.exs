defmodule Polyphony.Director.ArbitrationTest do
  @moduledoc "Stage-1 mechanical arbitration (§10) — pure and deterministic."
  use ExUnit.Case, async: true

  alias PolyphonyCore.Director.{Arbitration, Proposal, Options}

  defp options,
    do: Options.for_scene([%{label: "north gate"}, %{label: "cellar"}], ["lantern", "ledger"])

  test "an exit to a real connection is auto-accepted" do
    p = %Proposal{actor_id: "a", type: :exit, target: "north gate"}
    assert %{accepted: [^p], rejected: [], forwarded: []} = Arbitration.classify([p], options())
  end

  test "an exit to a nonexistent connection is auto-rejected" do
    p = %Proposal{actor_id: "a", type: :exit, target: "trapdoor"}

    assert %{accepted: [], rejected: [{^p, :no_such_exit}], forwarded: []} =
             Arbitration.classify([p], options())
  end

  test "interacting with a present entity is auto-accepted; an absent one is rejected" do
    ok = %Proposal{actor_id: "a", type: :interact, target: "lantern"}
    no = %Proposal{actor_id: "b", type: :interact, target: "sword"}

    result = Arbitration.classify([ok, no], options())
    assert ok in result.accepted
    assert {no, :no_such_entity} in result.rejected
  end

  test "novel proposals are always forwarded to judgment" do
    p = %Proposal{actor_id: "a", type: :novel, detail: "pries a brick loose to reveal a passage"}
    assert %{accepted: [], rejected: [], forwarded: [^p]} = Arbitration.classify([p], options())
  end

  test "a mixed batch is partitioned correctly" do
    ps = [
      %Proposal{actor_id: "a", type: :exit, target: "cellar"},
      %Proposal{actor_id: "b", type: :exit, target: "roof"},
      %Proposal{actor_id: "c", type: :novel, detail: "improvises"}
    ]

    r = Arbitration.classify(ps, options())
    assert length(r.accepted) == 1
    assert length(r.rejected) == 1
    assert length(r.forwarded) == 1
  end
end
