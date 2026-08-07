defmodule Polyphony.ForkTest do
  @moduledoc """
  Deliberate branching (§7): fork a scene at a beat into a new, independent stream
  that shares the prefix and then diverges. Runs end-to-end through Commanded —
  copy-on-fork means the fork is an ordinary scene, so the existing projections
  apply unchanged.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Fork, Reroll}
  alias Polyphony.Core.{Packets, MembershipSet, Visibility}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Events.{SceneForked, ThoughtOccurred, SpeechUttered}
  alias Polyphony.LLM.Mock

  defp new_scene, do: "fork-" <> Integer.to_string(System.unique_integer([:positive]))
  defp raw(scene), do: App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)
  defp canonical(scene), do: scene |> raw() |> Packets.canonical()

  defp packet_ids(events),
    do: events |> Enum.map(&Map.get(&1, :packet_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp commit(scene, char, beat, mark) do
    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "#{mark}-thought"},
        %Move{seq: 2, type: :speech, content: "#{mark}-speech"}
      ],
      self_state: %SelfState{mood_felt: "m", demeanor: "d"}
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

  # Parent scene: alice & bram present; packets at beat 2 and beat 3.
  defp parent_scene do
    scene = new_scene()
    :ok = App.dispatch(%OpenScene{scene_id: scene, campaign_id: "camp-1", opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "alice", beat: 1})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "bram", beat: 1})
    commit(scene, "alice", 2, "a2")
    commit(scene, "bram", 2, "b2")
    commit(scene, "alice", 3, "a3")
    scene
  end

  test "forking keeps the prefix through the fork beat and drops the rest" do
    parent = parent_scene()
    child = "#{parent}-branch"

    assert {:ok, ^child} = Fork.fork(parent, 2, new_scene_id: child, label: "what if")

    ids = child |> canonical() |> packet_ids()
    # Beats through 2 came across, re-pointed onto the child stream; beat 3 did not.
    assert "#{child}-2-alice" in ids
    assert "#{child}-2-bram" in ids
    refute Enum.any?(ids, &String.contains?(&1, "-3-"))
    # Every packet id was re-pointed onto the child stream — none dangles at the parent.
    assert Enum.all?(ids, &String.starts_with?(&1, "#{child}-"))
  end

  test "the fork records its lineage as a SceneForked marker" do
    parent = parent_scene()
    {:ok, child} = Fork.fork(parent, 2, label: "detour")

    assert %SceneForked{
             parent_scene_id: ^parent,
             fork_beat: 2,
             label: "detour",
             campaign_id: "camp-1"
           } = Enum.find(raw(child), &match?(%SceneForked{}, &1))
  end

  test "the fork is a live, playable scene that diverges from the parent" do
    parent = parent_scene()
    {:ok, child} = Fork.fork(parent, 2)

    # Beat 3 on the child goes a different way; the parent's beat 3 is untouched.
    commit(child, "alice", 3, "different")

    assert Enum.any?(
             canonical(child),
             &match?(%ThoughtOccurred{content: "different-thought"}, &1)
           )

    assert Enum.any?(canonical(parent), &match?(%ThoughtOccurred{content: "a3-thought"}, &1))
    refute Enum.any?(canonical(child), &match?(%ThoughtOccurred{content: "a3-thought"}, &1))
  end

  test "fork and parent are fully isolated — a re-roll on one never touches the other" do
    parent = parent_scene()
    {:ok, child} = Fork.fork(parent, 2)

    before = child |> canonical() |> packet_ids()

    # Re-roll the parent's latest beat; the child must not move.
    {:ok, _} = Reroll.reroll(parent, 3, "alice", provider: Mock)

    assert child |> canonical() |> packet_ids() == before
    # And the parent did re-roll — its beat-3 packet is now an r1 attempt.
    assert "#{parent}-3-alice-r1" in (parent |> canonical() |> packet_ids())
  end

  test "the dramatic-irony guarantee holds on the forked stream" do
    parent = parent_scene()
    {:ok, child} = Fork.fork(parent, 2)

    events = canonical(child)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    bram_view = Visibility.project(events, {:character, "bram"}, member_at?)

    assert Enum.any?(bram_view, &match?(%SpeechUttered{speaker_id: "alice"}, &1))
    refute Enum.any?(bram_view, &match?(%ThoughtOccurred{character_id: "alice"}, &1))
  end

  test "a re-rolled packet is not carried into the fork — only the canonical take" do
    parent = parent_scene()
    # Re-roll beat 3 on the parent so beat-2 stays canonical but there's supersession history.
    {:ok, _} = Reroll.reroll(parent, 3, "alice", provider: Mock)

    {:ok, child} = Fork.fork(parent, 3)
    ids = child |> canonical() |> packet_ids()

    # The child inherits the canonical r1 take, never the superseded base attempt.
    assert "#{child}-3-alice-r1" in ids
    refute "#{child}-3-alice" in ids
    refute Enum.any?(raw(child), &match?(%Polyphony.Events.PacketSuperseded{}, &1))
  end

  test "forking an unknown scene is rejected" do
    assert {:error, :unknown_scene} = Fork.fork("no-such-scene", 2)
  end
end
