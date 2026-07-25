defmodule Polyphony.DirectorTest do
  @moduledoc """
  The two-stage decision (§10): mechanical arbitration merged with a stubbed
  judgment call. No LLM — the provider is injected.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Director
  alias Polyphony.Director.{Proposal, Options}
  alias Polyphony.LLM.Stub
  alias Polyphony.Events.WorldEventOccurred

  defp decision_json(overrides \\ %{}) do
    Map.merge(
      %{
        "control" => "continue",
        "cast" => [%{"character_id" => "mira", "pacing_note" => "brief"}],
        "world_events" => [],
        "proposal_rulings" => []
      },
      overrides
    )
    |> Jason.encode!()
  end

  defp decide(opts) do
    Director.decide(
      Keyword.merge(
        [
          provider: Stub,
          scene_id: "S1",
          beat: 3,
          options: Options.for_scene([%{label: "gate"}], ["lantern"])
        ],
        opts
      )
    )
  end

  test "mechanically-rejected proposals become in-fiction world events, not errors" do
    p = %Proposal{actor_id: "otto", type: :exit, target: "chimney"}

    assert {:ok, resolved} = decide(proposals: [p], respond_with: {:ok, decision_json()})

    assert Enum.any?(resolved.world_events, fn e ->
             match?(%WorldEventOccurred{}, e) and e.content =~ "chimney" and e.scene_id == "S1"
           end)
  end

  test "auto-accepted proposals are carried into the resolved plan" do
    p = %Proposal{actor_id: "mira", type: :exit, target: "gate"}
    assert {:ok, resolved} = decide(proposals: [p], respond_with: {:ok, decision_json()})
    assert p in resolved.accepted
  end

  test "judgment rules on forwarded (novel) proposals; accepted ones join the plan" do
    novel = %Proposal{actor_id: "mira", type: :novel, detail: "pries loose a grate"}

    ruling = %{
      "control" => "continue",
      "cast" => [],
      "proposal_rulings" => [%{"actor_id" => "mira", "accept" => true}]
    }

    assert {:ok, resolved} =
             decide(proposals: [novel], respond_with: {:ok, decision_json(ruling)})

    assert novel in resolved.accepted
  end

  test "judgment can reject a forwarded proposal, producing a world event" do
    novel = %Proposal{actor_id: "otto", type: :novel, detail: "teleports away"}

    ruling = %{
      "control" => "continue",
      "cast" => [],
      "proposal_rulings" => [
        %{"actor_id" => "otto", "accept" => false, "reason" => "no magic in this world"}
      ]
    }

    assert {:ok, resolved} =
             decide(proposals: [novel], respond_with: {:ok, decision_json(ruling)})

    refute novel in resolved.accepted
    assert Enum.any?(resolved.world_events, &(&1.content =~ "no magic in this world"))
  end

  test "the ordered cast and control flow come straight from the decision" do
    j = %{
      "control" => "yield_to_user",
      "cast" => [%{"character_id" => "a"}, %{"character_id" => "b"}]
    }

    assert {:ok, resolved} = decide(respond_with: {:ok, decision_json(j)})
    assert Enum.map(resolved.cast, & &1.character_id) == ["a", "b"]
    assert resolved.control == :yield_to_user
  end

  test "an invalid decision is surfaced as an error, not a crash" do
    assert {:error, :invalid_decision} = decide(respond_with: {:ok, ~s({"control":"nonsense"})})
  end
end
