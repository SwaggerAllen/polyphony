defmodule Polyphony.SceneTest do
  @moduledoc """
  The Scene aggregate as pure functions: `execute/2` validates, `apply/2` folds.
  No runtime, no DB — Commanded replays these deterministically.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Scene
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  alias Polyphony.Commands.{
    OpenScene,
    CloseScene,
    EnterCharacter,
    ExitCharacter,
    CommitPacket,
    SupersedePacket
  }

  alias Polyphony.Events.{
    SceneOpened,
    SceneClosed,
    CharacterEntered,
    CharacterExited,
    ThoughtOccurred,
    SpeechUttered,
    ActionTaken,
    PrivateStateReported,
    DemeanorReported,
    PacketSuperseded
  }

  # Fold a list of events into aggregate state, as Commanded would on replay.
  defp evolve(state \\ %Scene{}, events), do: Enum.reduce(events, state, &Scene.apply(&2, &1))

  defp opened(scene \\ "S1") do
    evolve([%SceneOpened{scene_id: scene, opened_beat: 0}])
  end

  describe "lifecycle" do
    test "opening a pending scene emits SceneOpened" do
      assert %SceneOpened{scene_id: "S1", opened_beat: 0} =
               Scene.execute(%Scene{}, %OpenScene{scene_id: "S1", opened_beat: 0})
    end

    test "opening an already-open scene is rejected" do
      assert {:error, :scene_already_opened} =
               Scene.execute(opened(), %OpenScene{scene_id: "S1", opened_beat: 1})
    end

    test "closing a scene exits every remaining member, then closes" do
      state =
        opened()
        |> evolve([
          %CharacterEntered{scene_id: "S1", character_id: "B", beat: 1},
          %CharacterEntered{scene_id: "S1", character_id: "A", beat: 1}
        ])

      events = Scene.execute(state, %CloseScene{scene_id: "S1", closed_beat: 9})

      # Deterministic order (sorted) so replay is stable.
      assert [
               %CharacterExited{character_id: "A", beat: 9},
               %CharacterExited{character_id: "B", beat: 9},
               %SceneClosed{closed_beat: 9}
             ] = events
    end
  end

  describe "membership" do
    test "entering an open scene emits CharacterEntered" do
      assert %CharacterEntered{character_id: "A", beat: 1} =
               Scene.execute(opened(), %EnterCharacter{scene_id: "S1", character_id: "A", beat: 1})
    end

    test "entering a scene that is not open is rejected" do
      assert {:error, :scene_not_open} =
               Scene.execute(%Scene{}, %EnterCharacter{scene_id: "S1", character_id: "A", beat: 1})
    end

    test "double-entry is rejected" do
      state = opened() |> evolve([%CharacterEntered{scene_id: "S1", character_id: "A", beat: 1}])

      assert {:error, :already_present} =
               Scene.execute(state, %EnterCharacter{scene_id: "S1", character_id: "A", beat: 2})
    end

    test "exiting when not present is rejected" do
      assert {:error, :not_present} =
               Scene.execute(opened(), %ExitCharacter{scene_id: "S1", character_id: "A", beat: 2})
    end

    test "re-entry is allowed after an exit" do
      state =
        opened()
        |> evolve([
          %CharacterEntered{scene_id: "S1", character_id: "A", beat: 1},
          %CharacterExited{scene_id: "S1", character_id: "A", beat: 3}
        ])

      assert %CharacterEntered{character_id: "A", beat: 5} =
               Scene.execute(state, %EnterCharacter{scene_id: "S1", character_id: "A", beat: 5})
    end
  end

  describe "packet decomposition (§6.4)" do
    defp member_state do
      opened() |> evolve([%CharacterEntered{scene_id: "S1", character_id: "A", beat: 1}])
    end

    defp packet do
      %TurnPacket{
        moves: [
          %Move{seq: 1, type: :action, content: "crosses to the window"},
          %Move{seq: 2, type: :thought, content: "he's lying"},
          %Move{
            seq: 3,
            type: :speech,
            content: "Fine.",
            addressed_to: ["B"],
            audibility: :private
          }
        ],
        self_state: %SelfState{
          mood_felt: "furious",
          demeanor: "composed",
          intention: "leave soon",
          position: "by the window",
          posture: "arms crossed"
        }
      }
    end

    test "a packet becomes one event per move plus split self-state, sharing beat and packet_id" do
      cmd = %CommitPacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        packet: packet()
      }

      events = Scene.execute(member_state(), cmd)

      assert [
               %ActionTaken{seq: 1, content: "crosses to the window"},
               %ThoughtOccurred{seq: 2, content: "he's lying"},
               %SpeechUttered{seq: 3, audibility: :private, addressed_to: ["B"]},
               %PrivateStateReported{mood_felt: "furious", intention: "leave soon"},
               %DemeanorReported{demeanor: "composed", position: "by the window"}
             ] = events

      # Every decomposed event shares the packet's beat and id.
      assert Enum.all?(events, &(&1.beat == 2 and &1.packet_id == "p-1"))

      # Dramatic irony at the state layer: the private mood is on the self-only
      # event; the demeanor others read is on the scene-visible one.
      priv = Enum.find(events, &match?(%PrivateStateReported{}, &1))
      dem = Enum.find(events, &match?(%DemeanorReported{}, &1))
      assert priv.mood_felt == "furious"
      refute Map.get(dem, :mood_felt)
    end

    test "committing to a scene the character is not in is rejected" do
      cmd = %CommitPacket{
        scene_id: "S1",
        character_id: "Z",
        beat: 2,
        packet_id: "p-9",
        packet: packet()
      }

      assert {:error, :not_a_member} = Scene.execute(member_state(), cmd)
    end

    test "a duplicate packet_id is an idempotent no-op (§12)" do
      cmd = %CommitPacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        packet: packet()
      }

      first = Scene.execute(member_state(), cmd)
      # Apply the produced events, then replay the same command.
      state_after = evolve(member_state(), first)

      assert [] = Scene.execute(state_after, cmd)
    end
  end

  describe "supersession (§7 re-roll)" do
    # A member state with one committed packet, ready to be superseded.
    defp committed_state do
      cmd = %CommitPacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        packet: packet()
      }

      evolve(member_state(), Scene.execute(member_state(), cmd))
    end

    test "superseding a committed packet emits PacketSuperseded (append, not mutation)" do
      cmd = %SupersedePacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        attempt: 1,
        reason: "reroll"
      }

      assert %PacketSuperseded{packet_id: "p-1", attempt: 1, character_id: "A"} =
               Scene.execute(committed_state(), cmd)
    end

    test "the original committed events are untouched — supersession only records the marker" do
      before = committed_state()

      cmd = %SupersedePacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        attempt: 1
      }

      after_state = evolve(before, [Scene.execute(before, cmd)])

      # The packet stays 'committed' (immutability, rule 6); it is *also* marked
      # superseded, which is what the projection filter keys off.
      assert MapSet.member?(after_state.committed_packets, "p-1")
      assert MapSet.member?(after_state.superseded_packets, "p-1")
    end

    test "superseding a packet the scene never committed is rejected" do
      cmd = %SupersedePacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "ghost",
        attempt: 1
      }

      assert {:error, :unknown_packet} = Scene.execute(committed_state(), cmd)
    end

    test "a duplicate supersede is an idempotent no-op (§12)" do
      cmd = %SupersedePacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        attempt: 1
      }

      state_after = evolve(committed_state(), [Scene.execute(committed_state(), cmd)])

      assert [] = Scene.execute(state_after, cmd)
    end

    test "supersession is refused once the scene is closed" do
      closed = evolve(committed_state(), [%SceneClosed{scene_id: "S1", closed_beat: 9}])

      cmd = %SupersedePacket{
        scene_id: "S1",
        character_id: "A",
        beat: 2,
        packet_id: "p-1",
        attempt: 1
      }

      assert {:error, :scene_not_open} = Scene.execute(closed, cmd)
    end
  end
end
