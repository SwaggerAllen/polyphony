defmodule PolyphonyWeb.TurnEditTest do
  @moduledoc "Serialize / parse a whole turn — thoughts, speech, actions, demeanor."
  use ExUnit.Case, async: true

  alias PolyphonyWeb.TurnEdit
  alias PolyphonyCore.TurnPacket.Move

  defp msg(kind, payload), do: %{kind: kind, payload: payload}

  test "serialize renders every move type, in order, one per line" do
    msgs = [
      msg("ThoughtOccurred", %{character_id: "mira", content: "Careful now."}),
      msg("SpeechUttered", %{speaker_id: "mira", content: "Good evening.", audibility: "normal"}),
      msg("ActionTaken", %{character_id: "mira", content: "steps closer"}),
      msg("DemeanorReported", %{character_id: "mira", demeanor: "gracious"})
    ]

    assert TurnEdit.serialize(msgs) ==
             "thinks: Careful now.\nGood evening.\ndoes: steps closer\nseems: gracious"
  end

  test "private speech serializes as a whisper directive that round-trips" do
    msgs = [
      msg("SpeechUttered", %{
        speaker_id: "mira",
        content: "I don't trust him",
        audibility: "private",
        addressed_to: ["bram"]
      })
    ]

    text = TurnEdit.serialize(msgs)
    assert text == "(whisper to bram: I don't trust him)"

    {[move], _} = TurnEdit.parse(text)
    assert move.type == :speech
    assert move.audibility == :private
    assert move.addressed_to == ["bram"]
    assert move.content == "I don't trust him"
  end

  test "parse produces ordered thought/speech/action moves and folds demeanor into self-state" do
    text = "thinks: Careful now.\nGood evening.\ndoes: steps closer\nseems: gracious"

    {moves, self_state} = TurnEdit.parse(text)

    assert [
             %Move{seq: 1, type: :thought, content: "Careful now."},
             %Move{seq: 2, type: :speech, content: "Good evening."},
             %Move{seq: 3, type: :action, content: "steps closer"}
           ] = moves

    assert self_state.demeanor == "gracious"
  end

  test "a full serialize → parse round-trip preserves the move sequence" do
    msgs = [
      msg("ThoughtOccurred", %{character_id: "mira", content: "Who is he?"}),
      msg("ActionTaken", %{character_id: "mira", content: "sets down the cup"}),
      msg("SpeechUttered", %{speaker_id: "mira", content: "Sit, please.", audibility: "normal"})
    ]

    {moves, _} = msgs |> TurnEdit.serialize() |> TurnEdit.parse()

    assert Enum.map(moves, & &1.type) == [:thought, :action, :speech]
    assert Enum.map(moves, & &1.content) == ["Who is he?", "sets down the cup", "Sit, please."]
    assert Enum.map(moves, & &1.seq) == [1, 2, 3]
  end

  test "prefixes are case-insensitive and empty bodies are dropped" do
    {moves, _} = TurnEdit.parse("THINKS:  \nDoes: nods\n")
    assert [%Move{type: :action, content: "nods"}] = moves
  end

  test "an all-empty edit parses to no moves" do
    assert {[], _} = TurnEdit.parse("   \n\n")
  end
end
