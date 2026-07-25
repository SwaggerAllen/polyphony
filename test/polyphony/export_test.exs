defmodule Polyphony.ExportTest do
  @moduledoc """
  §B6: export. Tested hardest is the per-perspective transcript — a character export
  is `visible_to?` applied, so it can never leak a whisper the character wasn't part
  of. Plus the omniscient transcript and the structured JSON.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Export
  alias Polyphony.Authoring.CharacterSheet

  alias Polyphony.Events.{
    SpeechUttered,
    ThoughtOccurred,
    CharacterEntered,
    BeatOpened
  }

  # mira and otto are present; a whisper from mira to otto excludes cara.
  defp log do
    [
      %CharacterEntered{scene_id: "s", character_id: "mira", beat: 0},
      %CharacterEntered{scene_id: "s", character_id: "otto", beat: 0},
      %CharacterEntered{scene_id: "s", character_id: "cara", beat: 0},
      %BeatOpened{scene_id: "s", beat: 1},
      %ThoughtOccurred{scene_id: "s", character_id: "mira", content: "I distrust cara", beat: 1},
      %SpeechUttered{
        scene_id: "s",
        speaker_id: "mira",
        content: "meet me after",
        addressed_to: ["otto"],
        audibility: :private,
        beat: 1
      },
      %SpeechUttered{
        scene_id: "s",
        speaker_id: "cara",
        content: "lovely weather",
        addressed_to: [],
        audibility: :normal,
        beat: 1
      }
    ]
  end

  describe "transcript" do
    test "omniscient shows everything — the whisper and mira's private thought" do
      md = Export.transcript(log(), :omniscient)
      assert md =~ "Transcript (omniscient)"
      assert md =~ "**mira:** meet me after"
      assert md =~ "mira thinks: I distrust cara"
      assert md =~ "## Beat 1"
    end

    test "as cara: the whisper and mira's thought are absent, public speech present" do
      md = Export.transcript(log(), {:character, "cara"})
      assert md =~ "Transcript — as cara"
      assert md =~ "**cara:** lovely weather"
      # The guarantee: cara's export cannot contain what cara couldn't perceive.
      refute md =~ "meet me after"
      refute md =~ "I distrust cara"
    end

    test "as otto: the whisper IS present (otto was addressed)" do
      md = Export.transcript(log(), {:character, "otto"})
      assert md =~ "meet me after"
      # But not mira's private thought.
      refute md =~ "I distrust cara"
    end
  end

  describe "structured JSON" do
    test "embeds the omniscient event log and pinned deps" do
      json =
        Export.json(%{
          campaign_id: "camp",
          published_beat: 1,
          bible: nil,
          characters: [%{source_id: 1, source_version: 1, sheet: %CharacterSheet{name: "Mira"}}],
          arc: [%{status: "canon", statement: "they met", beat: 1}],
          events: log()
        })

      decoded = Jason.decode!(json)
      assert decoded["campaign_id"] == "camp"
      # Omniscient: the private whisper is in the structured log.
      assert Enum.any?(decoded["events"], &(&1["content"] == "meet me after"))
      assert [%{"statement" => "they met"}] = decoded["snapshot"]["arc"]
    end
  end

  test "entity_json encodes an authored entity" do
    json = Export.entity_json(%CharacterSheet{name: "Mira", premise: "An envoy."})
    assert Jason.decode!(json)["name"] == "Mira"
  end
end
