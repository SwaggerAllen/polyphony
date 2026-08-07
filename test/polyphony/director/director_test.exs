defmodule Polyphony.DirectorTest do
  @moduledoc """
  The two-stage decision (§10): mechanical arbitration merged with a stubbed
  judgment call. No LLM — the provider is injected.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Director
  alias PolyphonyCore.Director.{Proposal, Options}
  alias Polyphony.LLM.Stub
  alias PolyphonyCore.Events.WorldEventOccurred

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

  test "introduction proposals are carried into the resolved plan" do
    j = %{
      "introductions" => [%{"name" => "Bram", "reason" => "he's owed a debt"}]
    }

    assert {:ok, resolved} = decide(respond_with: {:ok, decision_json(j)})
    assert [%{name: "Bram", reason: "he's owed a debt"}] = resolved.introductions
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

  test "a malformed (decode-failing) response self-corrects on the next attempt" do
    # First reply is prose that won't decode; the retry returns valid JSON.
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    reply = fn _messages ->
      case Agent.get_and_update(agent, &{&1, &1 + 1}) do
        0 -> {:ok, "**Cast:** Lydia, Todd"}
        _ -> {:ok, decision_json(%{"cast" => [%{"character_id" => "lydia"}]})}
      end
    end

    assert {:ok, resolved} = decide(respond_with: reply)
    assert Enum.map(resolved.cast, & &1.character_id) == ["lydia"]
  end

  test "a persistent decode failure is a distinct error, not treated as empty" do
    # Always prose — decode always fails; distinct from an empty/blank response.
    assert {:error, {:director, :invalid_json}} =
             decide(respond_with: {:ok, "not json at all"})
  end

  test "the judgment prompt spells out the JSON contract (so the model can't free-form prose)" do
    test = self()

    capture = fn messages ->
      send(test, {:messages, messages})
      {:ok, decision_json()}
    end

    assert {:ok, _} = decide(respond_with: capture)

    assert_received {:messages, messages}
    text = messages |> Enum.map_join("\n", & &1.content)
    assert text =~ "Respond with ONLY a single JSON object"
    assert text =~ ~s("control")
    assert text =~ ~s("cast")
  end
end
