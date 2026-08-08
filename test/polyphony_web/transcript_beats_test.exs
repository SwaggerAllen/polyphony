defmodule PolyphonyWeb.TranscriptBeatsTest do
  @moduledoc """
  The transcript is a tree of beats, not a flat list of blocks with the beat copied onto
  each one.

  It was the latter, and both consumers then walked the result a second time to work out
  where a beat divider opened. Those were the same workaround twice: a flat list has
  nowhere to hang a divider, so the beat had to be duplicated onto every block (`eff_beat`)
  and re-derived from neighbours (`mark_beat_rules` in play, `with_beat_rules` in the
  reading view — two implementations of one rule, which is exactly what `Transcript` exists
  to prevent).

  In a tree the position *is* the beat. What this pins is the behaviour those walks used to
  produce, so the model change can be checked rather than assumed.
  """
  use ExUnit.Case, async: true

  alias PolyphonyWeb.Transcript

  defp msg(kind, payload), do: %{kind: kind, payload: payload}

  defp turn(packet_id, character, beat, content),
    do:
      msg("SpeechUttered", %{
        packet_id: packet_id,
        speaker_id: character,
        beat: beat,
        content: content
      })

  defp failure(id, beat), do: %{id: id, beat: beat, subject: "wren", retryable: true}

  describe "grouping" do
    test "a beat holds the turns that happened in it" do
      beats =
        Transcript.beats([
          turn("p1", "wren", 1, "One."),
          turn("p2", "ilias", 1, "Two."),
          turn("p3", "wren", 2, "Three.")
        ])

      assert [%{beat: 1, blocks: [_, _]}, %{beat: 2, blocks: [_]}] = beats
    end

    test "a packet's moves are one block, however many messages it is" do
      # The DOM unit is the block, not the message — a character's thought, speech and
      # action are one turn on screen. This is why a stream keyed by message would be
      # meaningless: it would key fragments of a block.
      beats =
        Transcript.beats([
          msg("DemeanorReported", %{packet_id: "p1", character_id: "wren", beat: 1}),
          turn("p1", "wren", 1, "Said."),
          msg("ActionTaken", %{packet_id: "p1", character_id: "wren", beat: 1, content: "Did."})
        ])

      assert [%{beat: 1, blocks: [block]}] = beats
      assert length(block.msgs) == 3
      assert block.type == :turn
      assert block.character == "wren"
    end

    test "an event with no beat of its own joins the beat it arrived in" do
      # Previously this was `eff_beat` inherited from the last turn. An append target
      # rather than a copied field — same answer, nothing duplicated.
      beats =
        Transcript.beats([
          turn("p1", "wren", 1, "One."),
          msg("WorldEventOccurred", %{beat: nil, content: "The bell."}),
          turn("p2", "wren", 2, "Two.")
        ])

      assert [%{beat: 1, blocks: [_turn, event]}, %{beat: 2}] = beats
      assert event.type == :event
    end

    test "anything before the first beat is beat 0, which draws no divider" do
      # Scene framing. The old `mark_block_beats` started its inheritance at 0 and
      # `with_beat_rules` refused to open a rule for it; the tree keeps both by making
      # beat 0 an ordinary container the markup skips the header on.
      beats = Transcript.beats([msg("SceneOpened", %{beat: nil, content: "A quay."})])

      assert [%{beat: 0, blocks: [_]}] = beats
    end

    test "nothing in, nothing out" do
      assert Transcript.beats([]) == []
    end
  end

  describe "failures" do
    test "file into the beat they happened in, after its turns" do
      beats =
        Transcript.beats([turn("p1", "wren", 1, "One."), turn("p2", "wren", 2, "Two.")])
        |> Transcript.with_failures([failure(9, 1)], 2)

      assert [%{beat: 1, failures: [%{id: 9}]}, %{beat: 2, failures: []}] = beats
    end

    test "a failure with no beat lands at the current one" do
      # Scene-close work — arc extraction, summarization — is emitted at whatever beat the
      # scene has reached, so it belongs with the latest action rather than at the top.
      beats =
        Transcript.beats([turn("p1", "wren", 1, "One."), turn("p2", "wren", 2, "Two.")])
        |> Transcript.with_failures([failure(9, nil)], 2)

      assert [%{beat: 1, failures: []}, %{beat: 2, failures: [%{id: 9}]}] = beats
    end

    test "a beat where everything failed still gets a container" do
      # It has no blocks, so it had no place in the old flat list and its failures rendered
      # under the previous beat's heading. It happened; it gets its own.
      beats =
        Transcript.beats([turn("p1", "wren", 1, "One.")])
        |> Transcript.with_failures([failure(9, 2)], 2)

      assert [%{beat: 1, blocks: [_]}, %{beat: 2, blocks: [], failures: [%{id: 9}]}] = beats
    end

    test "beats stay in order once failures have been filed" do
      beats =
        Transcript.beats([turn("p1", "wren", 3, "Three.")])
        |> Transcript.with_failures([failure(9, 1), failure(10, 2)], 3)

      assert Enum.map(beats, & &1.beat) == [1, 2, 3]
    end

    test "no failures is the untouched tree" do
      tree = Transcript.beats([turn("p1", "wren", 1, "One.")])
      assert Transcript.with_failures(tree, [], 1) == tree
    end
  end
end
