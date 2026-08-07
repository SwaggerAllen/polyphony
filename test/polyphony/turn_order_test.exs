defmodule Polyphony.TurnOrderTest do
  @moduledoc """
  §A1 turn order / control modes: reading the declarative facts, the beat
  aggregate's `passed` terminal state, and re-roll's control-mode reconciliation.
  The end-to-end beat-loop behavior (yields, resume, removal) lives on the Oban
  path — see `Polyphony.Jobs.ObanControlTest`.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Reroll}
  alias PolyphonyCore.{TurnOrder, Packets}
  alias Polyphony.LLM.Mock
  alias Polyphony.Director.BeatWalk
  alias PolyphonyCore.Director.Beat

  alias Polyphony.Commands.{
    OpenScene,
    EnterCharacter,
    CommitPacket,
    SetControlMode,
    DeclareTurnOrder
  }

  alias PolyphonyCore.Director.Commands.{OpenBeat, RecordPacket, RecordPass}
  alias PolyphonyCore.Events.{ThoughtOccurred, ControlModeSet, TurnOrderDeclared}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  defp stored(s), do: App |> Commanded.EventStore.stream_forward(s) |> Enum.map(& &1.data)
  defp canonical(s), do: s |> stored() |> Packets.canonical()

  defp commit(scene, char, beat, mark) do
    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "#{mark}-thought"},
        %Move{seq: 2, type: :speech, content: "#{mark}-speech"}
      ],
      self_state: %SelfState{}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: char,
        beat: beat,
        packet_id: "#{scene}-#{beat}-#{char}",
        packet: packet
      })
  end

  describe "reading the declarative facts (latest-wins)" do
    test "control mode defaults to autonomous and takes the latest set" do
      events = [
        %ControlModeSet{scene_id: "S", character_id: "a", control: "user_controlled"},
        %ControlModeSet{scene_id: "S", character_id: "a", control: "autonomous"}
      ]

      assert TurnOrder.control_mode(events, "a") == "autonomous"
      assert TurnOrder.control_mode(events, "unknown") == "autonomous"
      refute TurnOrder.user_controlled?(events, "a")
    end

    test "turn order is the latest declaration for the beat" do
      events = [
        %TurnOrderDeclared{scene_id: "S", beat: 2, order: ["a", "b", "c"]},
        %TurnOrderDeclared{scene_id: "S", beat: 2, order: ["b", "a"]}
      ]

      assert TurnOrder.for_beat(events, 2) == ["b", "a"]
      assert TurnOrder.for_beat(events, 9) == nil
    end
  end

  test "re-roll supersedes a user turn in the tail but never regenerates it" do
    scene = "a1-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- ["alice", "bram"],
        do: App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "bram",
        control: "user_controlled"
      })

    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram"]})

    commit(scene, "alice", 2, "alice")
    commit(scene, "bram", 2, "bram-orig")

    # Re-rolling alice puts bram (user-controlled) in the tail.
    assert {:ok, %{results: results}} = Reroll.reroll(scene, 2, "alice", provider: Mock)
    assert {"bram", :awaiting_user} in results

    # Bram's turn is superseded (it conditioned on the change) but not clobbered by
    # a generated one — it's the user's to re-write.
    refute Enum.any?(
             canonical(scene),
             &match?(%ThoughtOccurred{content: "bram-orig-thought"}, &1)
           )

    assert for(%ThoughtOccurred{character_id: "bram"} <- canonical(scene), do: 1) == []
  end

  test "BeatWalk picks the next non-terminal slot and its control mode" do
    scene = "bw-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- ["alice", "bram", "cara"],
        do: App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "bram",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    # Nothing committed yet → the first slot, autonomous.
    assert BeatWalk.next(scene, 2) == {:autonomous, "alice"}

    # Alice committed → the next slot is bram, who is user-controlled.
    commit(scene, "alice", 2, "alice")
    assert BeatWalk.next(scene, 2) == {:user_controlled, "bram"}
  end

  test "the beat aggregate counts a pass as terminal so a yielded beat can settle" do
    s0 = %Beat{}

    opened =
      Beat.apply(
        s0,
        Beat.execute(s0, %OpenBeat{beat_ref: "b", scene_id: "S", beat: 2, cast: ["a", "b"]})
      )

    refute Beat.settled?(opened)

    s1 = Beat.apply(opened, Beat.execute(opened, %RecordPacket{beat_ref: "b", character_id: "a"}))
    refute Beat.settled?(s1)

    s2 = Beat.apply(s1, Beat.execute(s1, %RecordPass{beat_ref: "b", character_id: "b"}))
    assert Beat.settled?(s2)
  end
end
