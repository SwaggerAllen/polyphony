defmodule Polyphony.Library.SnapshotTest do
  @moduledoc """
  §B1: the publish snapshot is a self-contained frozen copy. Tested: it embeds pinned
  dependency versions, its arc is **canon-only by default** and clipped to the
  published beat, and the published log is the **omniscient** projection.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Library.Snapshot
  alias Polyphony.Authoring.{WorldBible, CharacterSheet}
  alias PolyphonyCore.Events.{ThoughtOccurred, SpeechUttered}

  defp arc(status, statement, beat),
    do: %{status: status, statement: statement, beat: beat, subject_id: "mira"}

  describe "build/2 — embedding pinned dependencies" do
    test "embeds the bible and version-pinned character sheets" do
      snap =
        Snapshot.build(%{
          campaign_id: "camp",
          published_beat: 5,
          bible: %WorldBible{name: "Aldenmoor"},
          characters: [
            %{source_id: 1, source_version: 3, sheet: %CharacterSheet{name: "Mira"}}
          ],
          arc: []
        })

      assert %WorldBible{name: "Aldenmoor"} = snap.bible

      assert [%{source_id: 1, source_version: 3, sheet: %CharacterSheet{name: "Mira"}}] =
               snap.characters
    end
  end

  describe "arc resolution" do
    setup do
      arc = [
        arc("canon", "they met at the docks", 1),
        arc("proposed", "she may be a spy", 2),
        arc("canon", "a future canon fact", 9)
      ]

      %{arc: arc}
    end

    test "canon-only by default, clipped at the published beat", %{arc: arc} do
      snap = Snapshot.build(%{campaign_id: "c", published_beat: 5, arc: arc})
      statements = Enum.map(snap.arc, & &1.statement)

      assert "they met at the docks" in statements
      # proposed excluded, and beat-9 canon is past the published beat.
      refute "she may be a spy" in statements
      refute "a future canon fact" in statements
      refute snap.include_proposed
    end

    test "include_proposed: true opts the proposed tail in", %{arc: arc} do
      snap =
        Snapshot.build(%{campaign_id: "c", published_beat: 5, arc: arc}, include_proposed: true)

      statements = Enum.map(snap.arc, & &1.statement)
      assert "she may be a spy" in statements
      assert snap.include_proposed
    end

    test "entries with no beat (authored starting canon) are always kept" do
      snap =
        Snapshot.build(%{campaign_id: "c", published_beat: 0, arc: [arc("canon", "origin", nil)]})

      assert [%{statement: "origin"}] = snap.arc
    end
  end

  describe "omniscient_log/1 — the published view is omniscient" do
    test "a private thought and a whisper both survive the published projection" do
      events = [
        %ThoughtOccurred{scene_id: "s", character_id: "mira", content: "a secret", beat: 1},
        %SpeechUttered{
          scene_id: "s",
          speaker_id: "mira",
          content: "psst",
          addressed_to: ["otto"],
          audibility: :private,
          beat: 1
        }
      ]

      log = Snapshot.omniscient_log(events)
      assert length(log) == 2
    end
  end
end
