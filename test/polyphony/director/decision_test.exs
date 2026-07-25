defmodule Polyphony.Director.DecisionTest do
  @moduledoc "Validation of the Director's structured decision (§10)."
  use ExUnit.Case, async: true

  alias Polyphony.Director.Decision

  test "a well-formed decision parses" do
    data = %{
      "control" => "continue",
      "cast" => [
        %{"character_id" => "mira", "pacing_note" => "brief"},
        %{"character_id" => "otto"}
      ],
      "world_events" => [%{"content" => "A bell tolls in the distance."}],
      "proposal_rulings" => [%{"actor_id" => "mira", "accept" => true, "reason" => "plausible"}]
    }

    assert {:ok, decision} = Decision.parse(data)
    assert decision.control == :continue
    assert length(decision.cast) == 2
  end

  test "control is required and constrained" do
    assert {:error, _} = Decision.parse(%{"cast" => []})
    assert {:error, _} = Decision.parse(%{"control" => "keep_going"})
  end

  test "a pacing note containing dialogue is rejected (§10: cast, don't script)" do
    data = %{
      "control" => "continue",
      "cast" => [%{"character_id" => "mira", "pacing_note" => ~s(say "we're leaving now")}]
    }

    assert {:error, cs} = Decision.parse(data)
    refute cs.valid?
  end

  test "a directive pacing note (no dialogue) is allowed" do
    data = %{
      "control" => "yield_to_user",
      "cast" => [%{"character_id" => "mira", "pacing_note" => "don't answer yet"}]
    }

    assert {:ok, %Decision{control: :yield_to_user}} = Decision.parse(data)
  end

  test "scene actions carry an action enum" do
    data = %{
      "control" => "continue",
      "scene_actions" => [%{"action" => "close", "scene_id" => "S1"}]
    }

    assert {:ok, decision} = Decision.parse(data)
    assert [%{action: :close}] = decision.scene_actions
  end

  test "an empty cast is valid (everyone may pass)" do
    assert {:ok, %Decision{cast: []}} = Decision.parse(%{"control" => "yield_to_user"})
  end
end
