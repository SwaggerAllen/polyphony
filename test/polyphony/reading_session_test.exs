defmodule Polyphony.ReadingSessionTest do
  @moduledoc """
  Reading a published scene end-to-end (§3.1, §3.1b) — real committed events, projected
  through the same predicate that filters a character's context in play.

  This is the showcase and the risk in one: *the same scene from three heads* is the
  reason the reading surface exists, and it is also the one place a visibility mistake
  costs a reader a whole story rather than a beat. So the assertions are the ones the
  design's own copy makes — **Halden doesn't know what Ruthe already decided, and Ruthe
  doesn't hear what he says to the man on the stair** — checked against a real stream
  rather than a hand-built list.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo}
  alias PolyphonyCore.Publication
  alias PolyphonyCore.Commands.{CommitPacket, EnterCharacter, OpenScene}
  alias Polyphony.Library.Snapshot
  alias Polyphony.Reading
  alias Polyphony.Reading.Session
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}

  @halden "c-halden"
  @ruthe "c-ruthe"
  @ada "c-ada"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp stair do
    scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for id <- [@halden, @ruthe] do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: id, beat: 1})
    end

    commit(scene, @ruthe, 2, %TurnPacket{
      moves: [
        %Move{seq: 1, type: :action, content: "She puts out the lamp before he reaches it."},
        %Move{seq: 2, type: :thought, content: "Eleven years she has had the answer ready."}
      ],
      self_state: %SelfState{mood_felt: "certain", demeanor: "still"}
    })

    commit(scene, @halden, 2, %TurnPacket{
      moves: [
        %Move{seq: 1, type: :speech, content: "I know you're there.", audibility: :normal},
        %Move{seq: 2, type: :thought, content: "He does not know. He has not known."},
        %Move{
          seq: 3,
          type: :speech,
          content: "Say nothing to her.",
          audibility: :private,
          addressed_to: [@ada]
        }
      ],
      self_state: %SelfState{mood_felt: "bluffing", demeanor: "easy"}
    })

    scene
  end

  defp commit(scene, char, beat, packet) do
    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: char,
        beat: beat,
        packet_id: "#{scene}-#{beat}-#{char}",
        packet: packet
      })
  end

  defp snapshot(scene, pub_attrs) do
    Snapshot.build(%{
      campaign_id: "camp",
      publication: pub_attrs,
      scenes: [%{id: scene, title: "The stair at Ninth", cast: [@halden, @ruthe]}],
      characters: [
        %{source_id: @halden, source_version: 1, sheet: %{name: "Halden Voss"}},
        %{source_id: @ruthe, source_version: 1, sheet: %{name: "Ruthe Kell"}}
      ]
    })
  end

  defp texts(events) do
    Enum.flat_map(events, fn e -> List.wrap(Map.get(e, :content)) end)
  end

  describe "the same scene, twice" do
    test "each head gets their own interiority and not the other's" do
      scene = stair()
      snap = snapshot(scene, %{perspectives: [@halden, @ruthe]})

      {:ok, as_halden} = Reading.scene(snap, scene, {:character, @halden})
      {:ok, as_ruthe} = Reading.scene(snap, scene, {:character, @ruthe})

      assert "He does not know. He has not known." in texts(as_halden)
      refute "Eleven years she has had the answer ready." in texts(as_halden)

      assert "Eleven years she has had the answer ready." in texts(as_ruthe)
      refute "He does not know. He has not known." in texts(as_ruthe)
    end

    test "and Ruthe doesn't hear what he says to the man on the stair" do
      scene = stair()
      snap = snapshot(scene, %{perspectives: [@halden, @ruthe]})

      {:ok, as_halden} = Reading.scene(snap, scene, {:character, @halden})
      {:ok, as_ruthe} = Reading.scene(snap, scene, {:character, @ruthe})

      assert "Say nothing to her." in texts(as_halden)
      refute "Say nothing to her." in texts(as_ruthe)
    end

    test "both of them hear what was said aloud — the story still hangs together" do
      scene = stair()
      snap = snapshot(scene, %{perspectives: [@halden, @ruthe]})

      for mode <- [{:character, @halden}, {:character, @ruthe}, :spectator, :limited] do
        {:ok, events} = Reading.scene(snap, scene, mode)

        assert "I know you're there." in texts(events),
               "aloud speech missing from #{inspect(mode)}"
      end
    end
  end

  describe "everyone the author shared" do
    test "blends both heads, which is how prose fiction is actually written" do
      scene = stair()
      snap = snapshot(scene, %{perspectives: [@halden, @ruthe]})

      {:ok, events} = Reading.scene(snap, scene, :limited)

      assert "He does not know. He has not known." in texts(events)
      assert "Eleven years she has had the answer ready." in texts(events)
    end

    test "and stops exactly at the grant — an unshared head stays shut" do
      scene = stair()
      only_halden = snapshot(scene, %{perspectives: [@halden], spectator: false})

      {:ok, events} = Reading.scene(only_halden, scene, {:character, @halden})

      refute "Eleven years she has had the answer ready." in texts(events)
    end
  end

  describe "spectator" do
    test "everything said and done, nobody's thoughts, and no whisper" do
      scene = stair()
      snap = snapshot(scene, %{perspectives: [@halden, @ruthe]})

      {:ok, events} = Reading.scene(snap, scene, :spectator)
      said = texts(events)

      assert "I know you're there." in said
      assert "She puts out the lamp before he reaches it." in said
      refute "He does not know. He has not known." in said
      refute "Eleven years she has had the answer ready." in said
      refute "Say nothing to her." in said
    end
  end

  describe "what a URL can't get you" do
    test "a mode the author didn't grant is refused rather than filtered" do
      scene = stair()
      snap = snapshot(scene, %{perspectives: [@halden]})

      # Ruthe is in the story. Her head was kept back.
      assert {:error, :not_offered} = Reading.scene(snap, scene, {:character, @ruthe})
      # Someone who isn't in it at all, likewise.
      assert {:error, :not_offered} = Reading.scene(snap, scene, {:character, @ada})
    end

    test "a snapshot published before perspectives existed reads as spectator only" do
      scene = stair()
      snap = snapshot(scene, nil)

      assert {:ok, events} = Reading.scene(snap, scene, :spectator)
      refute "He does not know. He has not known." in texts(events)
      assert {:error, :not_offered} = Reading.scene(snap, scene, {:character, @halden})
    end
  end

  describe "the two kinds of empty" do
    test "they weren't there — a fact about the reader, with a way out" do
      snap = snapshot("sX", %{perspectives: [@halden, @ruthe]})
      elsewhere = %{id: "s5", title: "Sixth", cast: [@ruthe]}

      assert Session.gap(snap, elsewhere, {:character, @halden}) == :not_present
      assert Session.gap(snap, elsewhere, {:character, @ruthe}) == nil
    end

    test "nobody's side was shared — a fact about the publication, with none" do
      snap = snapshot("sX", %{perspectives: [@halden], spectator: false})
      unshared = %{id: "s5", title: "The counting house, after", cast: [@ada]}

      assert Session.gap(snap, unshared, {:character, @halden}) == :not_shared
    end

    test "with spectator on there is no such thing as unshared" do
      snap = snapshot("sX", %{perspectives: [@halden], spectator: true})
      unshared = %{id: "s5", title: "The counting house, after", cast: [@ada]}

      assert Session.gap(snap, unshared, :spectator) == nil
    end
  end

  describe "getting around the story" do
    test "position is one-based and comes from the snapshot, not the live campaign" do
      snap =
        Snapshot.build(%{
          campaign_id: "camp",
          scenes: [%{id: "a"}, %{id: "b"}, %{id: "c"}]
        })

      assert Session.position(snap, "b") == {2, 3}
      assert Session.position(snap, "zz") == nil
      assert %{id: "c"} = Session.next_scene(snap, "b")
      assert Session.next_scene(snap, "c") == nil
    end

    test "names come from the pinned sheets, never the author's live library" do
      snap = snapshot("sX", %{perspectives: [@halden]})

      assert Session.names(snap) == %{@halden => "Halden Voss", @ruthe => "Ruthe Kell"}
    end

    test "a sheet is readable only where forking is offered" do
      read_only = snapshot("sX", %{perspectives: [@halden, @ruthe]})
      forkable = snapshot("sX", %{perspectives: [@halden], forkable: true})

      assert Session.sheet(read_only, @halden) == nil
      assert %{name: "Halden Voss"} = Session.sheet(forkable, @halden)
    end
  end

  describe "publication travels with the snapshot" do
    test "so it can't change under a reader who is partway through" do
      snap = snapshot("sX", %{perspectives: [@halden, @ruthe], forkable: true})

      pub = Session.publication(snap)
      assert Publication.limited?(pub)
      assert Publication.forkable?(pub)
    end
  end
end
