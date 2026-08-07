defmodule Polyphony.Generation.PacketSchemaTest do
  @moduledoc "Validation of generated packets against the §6.4 rules (pure)."
  use ExUnit.Case, async: true

  alias Polyphony.Generation.PacketSchema
  alias PolyphonyCore.TurnPacket

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

  test "addressed_to on a non-speech move is stripped, not rejected (§6.4: speech-only)" do
    # The model habitually tags thoughts/actions with speech-only fields; normalize them
    # away rather than reject-and-retry (a wasted generation on nearly every turn).
    data = %{
      "moves" => [%{"seq" => 1, "type" => "action", "content" => "nods", "addressed_to" => ["b"]}]
    }

    assert {:ok, %{moves: [move]}} = PacketSchema.parse(data)
    assert move.type == :action
    assert move.addressed_to == []
  end

  test "private audibility on a non-speech move is normalized to :normal, not rejected" do
    data = %{
      "moves" => [
        %{"seq" => 1, "type" => "thought", "content" => "psst", "audibility" => "private"}
      ]
    }

    assert {:ok, %{moves: [move]}} = PacketSchema.parse(data)
    assert move.type == :thought
    assert move.audibility == :normal
  end

  test "error_messages renders human-readable errors for the corrective retry" do
    {:error, cs} = PacketSchema.parse(%{"moves" => []})
    msg = PacketSchema.error_messages(cs)
    assert is_binary(msg)
    assert msg =~ "move"
  end

  test "error_messages doesn't crash on an Ecto.Enum cast error (the type opt isn't stringable)" do
    # A bad `type` produces an enum cast error whose opts carry the parameterized type
    # tuple; error_messages must render it (for the retry) instead of raising.
    {:error, cs} =
      PacketSchema.parse(%{"moves" => [%{"seq" => 1, "type" => "singing", "content" => "la"}]})

    msg = PacketSchema.error_messages(cs)
    assert is_binary(msg)
  end

  test "an out-of-range audibility is dropped (defaults to :normal), not a cast failure" do
    data = %{
      "moves" => [
        %{"seq" => 1, "type" => "speech", "content" => "Hi", "audibility" => "public"}
      ]
    }

    assert {:ok, %{moves: [move]}} = PacketSchema.parse(data)
    assert move.audibility == :normal
  end
end
