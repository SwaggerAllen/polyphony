defmodule Polyphony.Generation.PacketSchemaTest do
  @moduledoc "Validation of generated packets against the §6.4 rules (pure)."
  use ExUnit.Case, async: true

  alias Polyphony.Generation.PacketSchema
  alias Polyphony.TurnPacket

  defp valid_moves,
    do: [%{"seq" => 1, "type" => "thought", "content" => "hmm"}]

  test "a well-formed packet parses into a domain TurnPacket" do
    data = %{
      "moves" => [
        %{"seq" => 1, "type" => "action", "content" => "steps inside"},
        %{
          "seq" => 2,
          "type" => "speech",
          "content" => "Hello.",
          "addressed_to" => ["b"],
          "audibility" => "private"
        }
      ],
      "self_state" => %{"mood_felt" => "tense", "demeanor" => "calm"}
    }

    assert {:ok, %TurnPacket{moves: [m1, m2], self_state: state}} = PacketSchema.parse(data)
    assert m1.type == :action
    assert m2.type == :speech and m2.audibility == :private and m2.addressed_to == ["b"]
    assert state.mood_felt == "tense" and state.demeanor == "calm"
  end

  test "self_state is optional" do
    assert {:ok, %TurnPacket{self_state: nil}} = PacketSchema.parse(%{"moves" => valid_moves()})
  end

  test "a packet with no moves is rejected" do
    assert {:error, cs} = PacketSchema.parse(%{"moves" => []})
    refute cs.valid?
  end

  test "more than five moves is rejected (§6.4 cap)" do
    moves = for i <- 1..6, do: %{"seq" => i, "type" => "speech", "content" => "line #{i}"}
    assert {:error, _cs} = PacketSchema.parse(%{"moves" => moves})
  end

  test "exactly five moves is allowed" do
    moves = for i <- 1..5, do: %{"seq" => i, "type" => "speech", "content" => "line #{i}"}
    assert {:ok, %TurnPacket{moves: five}} = PacketSchema.parse(%{"moves" => moves})
    assert length(five) == 5
  end

  test "blank content is rejected" do
    assert {:error, _} =
             PacketSchema.parse(%{
               "moves" => [%{"seq" => 1, "type" => "thought", "content" => "   "}]
             })
  end

  test "an unknown move type is rejected" do
    assert {:error, _} =
             PacketSchema.parse(%{
               "moves" => [%{"seq" => 1, "type" => "singing", "content" => "la"}]
             })
  end

  test "addressed_to on a non-speech move is rejected (§6.4: speech-only)" do
    data = %{
      "moves" => [%{"seq" => 1, "type" => "action", "content" => "nods", "addressed_to" => ["b"]}]
    }

    assert {:error, _} = PacketSchema.parse(data)
  end

  test "private audibility on a non-speech move is rejected" do
    data = %{
      "moves" => [
        %{"seq" => 1, "type" => "thought", "content" => "psst", "audibility" => "private"}
      ]
    }

    assert {:error, _} = PacketSchema.parse(data)
  end

  test "error_messages renders human-readable errors for the corrective retry" do
    {:error, cs} = PacketSchema.parse(%{"moves" => []})
    msg = PacketSchema.error_messages(cs)
    assert is_binary(msg)
    assert msg =~ "move"
  end
end
