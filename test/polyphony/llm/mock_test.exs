defmodule Polyphony.LLM.MockTest do
  @moduledoc "The lorem-ipsum Mock provider emits schema-valid output. Pure."
  use ExUnit.Case, async: true

  alias Polyphony.LLM.Mock
  alias Polyphony.Generation.PacketSchema
  alias Polyphony.Director.Decision

  test "a :turn_packet response parses as a valid TurnPacket" do
    {:ok, json} = Mock.complete([%{role: "user", content: "your turn"}], response: :turn_packet)
    {:ok, data} = Jason.decode(json)
    assert {:ok, _packet} = PacketSchema.parse(data)
  end

  test "a :decision response casts the hint and echoes control" do
    {:ok, json} =
      Mock.complete([], response: :decision, cast_hint: ["mira", "otto"], control_hint: :continue)

    {:ok, data} = Jason.decode(json)
    assert {:ok, decision} = Decision.parse(data)
    assert Enum.map(decision.cast, & &1.character_id) == ["mira", "otto"]
    assert decision.control == :continue
  end

  test "control defaults to yield_to_user so a mock loop terminates" do
    {:ok, json} = Mock.complete([], response: :decision, cast_hint: ["a"])
    {:ok, %Decision{control: :yield_to_user}} = Decision.parse(Jason.decode!(json))
  end

  test "output is deterministic for identical input" do
    msgs = [%{role: "user", content: "same"}]

    assert Mock.complete(msgs, response: :turn_packet) ==
             Mock.complete(msgs, response: :turn_packet)
  end
end
