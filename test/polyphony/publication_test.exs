defmodule Polyphony.PublicationTest do
  @moduledoc """
  What publishing decides (§3.1, §3.1b, §3.1c, §3.1c-ii), and the two reading viewers
  it rests on.

  The visibility half is tested hardest, because it is the guarantee: **limited
  omniscient must be a union over the granted perspectives and nothing beyond them**,
  and **spectator must have no interiority at all**. A reading mode that shows a
  thought the author didn't share is the same failure as a character knowing something
  they never witnessed — it just costs a reader a story instead of a scene.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Core.{Publication, Visibility}

  alias Polyphony.Events.{
    ThoughtOccurred,
    PrivateStateReported,
    SpeechUttered,
    ActionTaken,
    WorldEventOccurred,
    CharacterEntered,
    IntroductionProposed
  }

  # Halden and Ruthe are on the stair; Ada is elsewhere and unshared.
  @halden "c-halden"
  @ruthe "c-ruthe"
  @ada "c-ada"

  defp members(scene, ids) do
    fn s, char, _beat -> s == scene and char in ids end
  end

  defp stair, do: members("s1", [@halden, @ruthe])

  defp pub(attrs), do: Publication.from(Map.merge(%{perspectives: [@halden]}, attrs))

  describe "spectator — what a camera caught" do
    test "speech and action, and nothing anyone was thinking" do
      spoken = %SpeechUttered{scene_id: "s1", beat: 2, speaker_id: @halden, content: "I know."}
      acted = %ActionTaken{scene_id: "s1", beat: 2, character_id: @ruthe, content: "puts it out"}
      world = %WorldEventOccurred{scene_id: "s1", beat: 2, content: "a door opens"}
      entered = %CharacterEntered{scene_id: "s1", beat: 1, character_id: @ruthe}

      for e <- [spoken, acted, world, entered] do
        assert Visibility.visible_to?(e, :spectator, stair())
      end

      thought = %ThoughtOccurred{scene_id: "s1", beat: 2, character_id: @halden, content: "lying"}

      state = %PrivateStateReported{
        scene_id: "s1",
        beat: 2,
        character_id: @halden,
        mood_felt: "x"
      }

      refute Visibility.visible_to?(thought, :spectator, stair())
      refute Visibility.visible_to?(state, :spectator, stair())
    end

    test "a whisper is not something a camera in the room catches" do
      whisper = %SpeechUttered{
        scene_id: "s1",
        beat: 2,
        speaker_id: @halden,
        addressed_to: [@ruthe],
        audibility: :private,
        content: "meet me after"
      }

      refute Visibility.visible_to?(whisper, :spectator, stair())
      # …while the same words said aloud are.
      assert Visibility.visible_to?(%{whisper | audibility: :normal}, :spectator, stair())
    end

    test "default-deny holds: author-facing tooling never reaches a reader" do
      refute Visibility.visible_to?(%IntroductionProposed{scene_id: "s1"}, :spectator, stair())
    end
  end

  describe "limited omniscient — the union, and only the union" do
    test "sees what any shared head saw" do
      halden_thought = %ThoughtOccurred{
        scene_id: "s1",
        beat: 2,
        character_id: @halden,
        content: "x"
      }

      ruthe_thought = %ThoughtOccurred{
        scene_id: "s1",
        beat: 2,
        character_id: @ruthe,
        content: "y"
      }

      viewer = {:readers, [@halden, @ruthe]}

      assert Visibility.visible_to?(halden_thought, viewer, stair())
      assert Visibility.visible_to?(ruthe_thought, viewer, stair())
    end

    test "and nothing beyond it — an unshared head stays shut" do
      ada = %ThoughtOccurred{scene_id: "s1", beat: 2, character_id: @ada, content: "the ledger"}

      refute Visibility.visible_to?(ada, {:readers, [@halden, @ruthe]}, stair())
      # The spoiler control, working: publishing two heads is not publishing all three.
      assert Visibility.visible_to?(ada, :omniscient, stair())
    end

    test "a whisper reaches it only if a shared perspective was in on it" do
      whisper = %SpeechUttered{
        scene_id: "s1",
        beat: 2,
        speaker_id: @ada,
        addressed_to: [@ruthe],
        audibility: :private,
        content: "not a word"
      }

      assert Visibility.visible_to?(whisper, {:readers, [@ruthe]}, stair())
      refute Visibility.visible_to?(whisper, {:readers, [@halden]}, stair())
    end

    test "granting nothing sees nothing — default-deny, not everything" do
      spoken = %SpeechUttered{scene_id: "s1", beat: 2, speaker_id: @halden, content: "hello"}
      refute Visibility.visible_to?(spoken, {:readers, []}, stair())
    end

    test "membership still binds: a shared head sees only what they were there for" do
      elsewhere = %SpeechUttered{scene_id: "s2", beat: 1, speaker_id: @ada, content: "elsewhere"}

      # Halden and Ruthe are members of s1 only.
      refute Visibility.visible_to?(elsewhere, {:readers, [@halden, @ruthe]}, stair())
    end
  end

  describe "what publishing grants" do
    test "settings a snapshot never had grant the least" do
      old = Publication.from(nil)

      assert old.perspectives == []
      assert old.spectator
      refute Publication.forkable?(old)
      assert Publication.modes(old) == [:spectator]
    end

    test "everyone-shared appears only above one perspective" do
      one = pub(%{perspectives: [@halden]})
      two = pub(%{perspectives: [@halden, @ruthe]})

      refute Publication.limited?(one)
      assert Publication.limited?(two)

      # With one head, offering "everyone shared" would promise more than it gives.
      assert Publication.modes(one) == [:spectator, {:character, @halden}]
      assert [:limited | _] = Publication.modes(two)
    end

    test "a publisher can leave spectator out, and it isn't a lesser tier" do
      p = pub(%{perspectives: [@halden, @ruthe], spectator: false})

      assert Publication.modes(p) == [:limited, {:character, @halden}, {:character, @ruthe}]
      assert Publication.default_mode(p) == :limited
    end

    test "a mode that wasn't granted is refused, however it's asked for" do
      p = pub(%{perspectives: [@halden]})

      assert Publication.offers?(p, {:character, @halden})
      # Ada is in the story; her head was kept back. A URL naming her is not a grant.
      refute Publication.offers?(p, {:character, @ada})
      refute Publication.offers?(p, :limited)
    end

    test "granting nothing at all is a real state, not a crash" do
      p = pub(%{perspectives: [], spectator: false})

      assert Publication.modes(p) == []
      assert Publication.default_mode(p) == nil
    end

    test "forkable brings sheets, and nothing else does" do
      read_only = pub(%{perspectives: [@halden, @ruthe]})
      forkable = pub(%{perspectives: [@halden], forkable: true})

      refute Publication.sheets?(read_only)
      assert Publication.sheets?(forkable)
    end

    test "how it's read and whether it forks are independent" do
      # Two heads, not forkable: shared to be read, not continued.
      p = pub(%{perspectives: [@halden, @ruthe], forkable: false})
      assert Publication.limited?(p)
      refute Publication.forkable?(p)
    end

    test "the viewer is the only seam — publication picks who, visibility picks what" do
      p = pub(%{perspectives: [@halden, @ruthe]})

      assert Publication.viewer(p, :limited) == {:readers, [@halden, @ruthe]}
      assert Publication.viewer(p, :spectator) == :spectator
      assert Publication.viewer(p, {:character, @halden}) == {:character, @halden}
    end
  end

  describe "which scenes a mode can show (§3.1c-ii)" do
    test "a character can only show you a scene they were in" do
      p = pub(%{perspectives: [@halden, @ruthe]})

      assert Publication.covers_scene?(p, {:character, @halden}, [@halden, @ruthe])
      refute Publication.covers_scene?(p, {:character, @halden}, [@ruthe, @ada])
    end

    test "spectator can show any scene, which is why it's one of the two fixes" do
      p = pub(%{perspectives: [@halden]})
      assert Publication.covers_scene?(p, :spectator, [@ada])
    end

    test "the selector keeps the reader's current perspective last, never removes it" do
      p = pub(%{perspectives: [@halden, @ruthe]})

      %{can: can, cannot: cannot} =
        Publication.modes_for_scene(p, [@ruthe], {:character, @halden})

      # Halden wasn't there, so he's in `cannot` — and the control doesn't reorder.
      assert {:character, @halden} in cannot
      assert {:character, @ruthe} in can
      assert :limited in can
    end

    test "a current perspective that can show the scene sinks to the bottom" do
      p = pub(%{perspectives: [@halden, @ruthe]})

      %{can: can} = Publication.modes_for_scene(p, [@halden, @ruthe], {:character, @halden})

      assert List.last(can) == {:character, @halden}
    end
  end

  describe "the publish-time warning" do
    @scenes [
      %{id: "s1", title: "The stair at Ninth", cast: ["c-halden", "c-ruthe"]},
      %{id: "s5", title: "The counting house, after", cast: ["c-ada", "c-clerk"]}
    ]

    test "names the scene nobody will be able to read" do
      p = pub(%{perspectives: [@halden, @ruthe], spectator: false})

      assert [%{title: "The counting house, after"}] = Publication.unreadable_scenes(p, @scenes)
    end

    test "spectator on means there's nothing to warn about" do
      p = pub(%{perspectives: [@halden], spectator: true})
      assert Publication.unreadable_scenes(p, @scenes) == []
    end

    test "sharing one of the people who were there is the other fix" do
      p = pub(%{perspectives: [@halden, @ada], spectator: false})
      assert Publication.unreadable_scenes(p, @scenes) == []
    end

    test "it warns, and never blocks — sometimes a gap is the point" do
      p = pub(%{perspectives: [], spectator: false})
      # Everything unreadable, and this is still just a list.
      assert length(Publication.unreadable_scenes(p, @scenes)) == 2
    end

    test "the front page says how many people you don't get" do
      p = pub(%{perspectives: [@halden, @ruthe]})
      assert Publication.withheld(p, [@halden, @ruthe, @ada, "c-clerk"]) == 2
    end
  end
end
