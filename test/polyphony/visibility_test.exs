defmodule Polyphony.VisibilityTest do
  @moduledoc """
  The core guarantee (§8, §15 slice 1): a character's projection contains only
  what they could structurally witness. Tested hardest, with hand-written
  events and no runtime — if these pass, dramatic irony is a property of the
  data, not of a prompt.
  """
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario

  alias Polyphony.Core.Visibility
  alias Polyphony.Events.{ArcEntryProposed, SceneOpened, BeatClosed}

  # A shared scene the size of a real beat sequence.
  #
  #   S1: A, B, D present from beat 1; D leaves at beat 4.
  #   S2: C, alone.
  #
  # Ids are strings for readability; the projection is id-agnostic.
  defp log do
    [
      scene_opened("S1", 0),
      scene_opened("S2", 0),
      entered("S1", "A", 1),
      entered("S1", "B", 1),
      entered("S1", "D", 1),
      entered("S2", "C", 1),
      thought("A", "S1", 2, "I don't trust B"),
      private_state("A", "S1", 2, mood_felt: "afraid"),
      speech("A", "S1", 2, "Hello"),
      demeanor("A", "S1", 2, demeanor: "calm"),
      action("B", "S1", 2, "draws a dagger"),
      speech("A", "S1", 3, "psst — meet me later", addressed_to: ["B"], audibility: :private),
      world_event("S1", 3, "thunder cracks"),
      exited("S1", "D", 4),
      speech("A", "S1", 5, "is he gone?"),
      thought("C", "S2", 2, "where am I?"),
      generation_failed(5, "B", :refusal),
      beat_opened(2, ["A", "B"])
    ]
  end

  defp project(viewer), do: Visibility.project(log(), viewer)

  # A small predicate helper: does the projection contain an event matching?
  defp seen?(events, fun), do: Enum.any?(events, fun)

  describe "interior events are self-only" do
    test "a character cannot see another character's thoughts" do
      b_view = project({:character, "B"})

      # B is present in the same scene at the same beat and still never sees
      # A's interior monologue — the whole point of the system.
      refute seen?(b_view, &match?(%Polyphony.Events.ThoughtOccurred{character_id: "A"}, &1))
    end

    test "a character sees their own thoughts" do
      a_view = project({:character, "A"})

      assert Enum.any?(a_view, fn e ->
               e.__struct__ == Polyphony.Events.ThoughtOccurred and e.content == "I don't trust B"
             end)
    end

    test "private self-state is self-only" do
      b_view = project({:character, "B"})

      refute Enum.any?(b_view, &match?(%Polyphony.Events.PrivateStateReported{}, &1))

      a_view = project({:character, "A"})

      assert Enum.any?(
               a_view,
               &match?(%Polyphony.Events.PrivateStateReported{mood_felt: "afraid"}, &1)
             )
    end
  end

  describe "scene isolation" do
    test "a character cannot see events from a scene they were never in" do
      c_view = project({:character, "C"})

      # C is in S2 only — nothing from S1 leaks in.
      refute Enum.any?(c_view, fn e -> Map.get(e, :scene_id) == "S1" end)

      # ...and A, in S1, never sees C's S2 interior.
      a_view = project({:character, "A"})
      refute Enum.any?(a_view, fn e -> Map.get(e, :scene_id) == "S2" end)
    end

    test "C sees only their own S2 events" do
      c_view = project({:character, "C"})

      assert Enum.any?(c_view, &match?(%Polyphony.Events.CharacterEntered{character_id: "C"}, &1))

      assert Enum.any?(
               c_view,
               &match?(%Polyphony.Events.ThoughtOccurred{content: "where am I?"}, &1)
             )
    end
  end

  describe "whispers (private speech)" do
    test "reach the speaker and addressees only" do
      # D is present in S1 at beat 3 but is NOT addressed — must not hear it.
      d_view = project({:character, "D"})

      refute Enum.any?(d_view, fn e ->
               match?(%Polyphony.Events.SpeechUttered{audibility: :private}, e)
             end)
    end

    test "the addressee and speaker do hear it" do
      whisper? = fn e -> match?(%Polyphony.Events.SpeechUttered{audibility: :private}, e) end

      assert Enum.any?(project({:character, "A"}), whisper?), "speaker hears own whisper"
      assert Enum.any?(project({:character, "B"}), whisper?), "addressee hears whisper"
    end
  end

  describe "membership is evaluated at the event's beat, not now" do
    test "a character who has left does not see later moves" do
      d_view = project({:character, "D"})

      # D left at beat 4 (half-open interval): the beat-5 line is invisible.
      refute Enum.any?(d_view, fn e ->
               match?(%Polyphony.Events.SpeechUttered{beat: 5}, e)
             end)

      # But D did witness the beat-2 and beat-3 scene events.
      assert Enum.any?(d_view, &match?(%Polyphony.Events.SpeechUttered{beat: 2}, &1))
      assert Enum.any?(d_view, &match?(%Polyphony.Events.WorldEventOccurred{beat: 3}, &1))
    end

    test "characters still present witness a departure" do
      # A remains in S1, so A sees D exit at beat 4.
      a_view = project({:character, "A"})

      assert Enum.any?(a_view, &match?(%Polyphony.Events.CharacterExited{character_id: "D"}, &1))
    end
  end

  describe "default deny (rule 3)" do
    test "scene lifecycle, beat structure, and generation failures never reach a character" do
      for viewer <- [{:character, "A"}, {:character, "B"}, {:character, "C"}, {:character, "D"}] do
        view = project(viewer)

        refute Enum.any?(view, &match?(%Polyphony.Events.SceneOpened{}, &1)),
               "#{inspect(viewer)} must not see SceneOpened"

        refute Enum.any?(view, &match?(%Polyphony.Events.BeatOpened{}, &1)),
               "#{inspect(viewer)} must not see BeatOpened"

        refute Enum.any?(view, &match?(%Polyphony.Events.GenerationFailed{}, &1)),
               "#{inspect(viewer)} must not see GenerationFailed"
      end
    end

    test "an unrecognized/new event type is denied to characters but shown to the omniscient viewer" do
      deny = fn _scene, _char, _beat -> false end

      # Events with no explicit clause fall through to default-deny.
      assert Visibility.visible_to?(%ArcEntryProposed{statement: "x"}, {:character, "A"}, deny) ==
               false

      assert Visibility.visible_to?(%SceneOpened{scene_id: "S1"}, {:character, "A"}, deny) ==
               false

      assert Visibility.visible_to?(%BeatClosed{beat: 1}, {:character, "A"}, deny) == false

      assert Visibility.visible_to?(%ArcEntryProposed{statement: "x"}, :omniscient, deny) == true
    end
  end

  describe "the omniscient viewer" do
    test "sees the entire log, routed through the same predicate" do
      full = log()
      assert Visibility.project(full, :omniscient) == full
    end

    test "including interior events and generation failures the characters cannot see" do
      omni = Visibility.project(log(), :omniscient)

      assert Enum.any?(omni, &match?(%Polyphony.Events.GenerationFailed{}, &1))
      assert Enum.any?(omni, &match?(%Polyphony.Events.ThoughtOccurred{}, &1))
    end
  end

  describe "order is preserved" do
    test "projection is a filter, never a reorder" do
      a_view = project({:character, "A"})
      beats = a_view |> Enum.map(&Map.get(&1, :beat)) |> Enum.reject(&is_nil/1)
      assert beats == Enum.sort(beats)
    end
  end
end
