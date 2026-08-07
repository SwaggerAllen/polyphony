defmodule Polyphony.RerollTest do
  @moduledoc """
  Re-rolls (§7, §12): supersede a turn and regenerate the rest of its beat in
  place — no fork, no new stream. Runs end-to-end through Commanded with the Mock
  provider: real `SupersedePacket`/`CommitPacket` land in the store and the
  canonical view reflects the re-roll.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Reroll}
  alias PolyphonyCore.{Packets, MembershipSet, Visibility}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias PolyphonyCore.Events.{ThoughtOccurred, SpeechUttered, PacketSuperseded}
  alias Polyphony.LLM.Mock

  defp new_scene, do: "reroll-" <> Integer.to_string(System.unique_integer([:positive]))

  defp raw(scene), do: App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)
  defp canonical(scene), do: scene |> raw() |> Packets.canonical()

  defp open_with(scene, chars) do
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- chars,
        do: :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})
  end

  defp commit(scene, char, beat, packet_id, mark) do
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
        packet_id: packet_id,
        packet: packet
      })
  end

  defp packet_ids(events),
    do: events |> Enum.map(&Map.get(&1, :packet_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp superseded_markers(scene),
    do: for(%PacketSuperseded{packet_id: id} <- raw(scene), do: id)

  # A beat of three committed packets, alice → bram → cara, at beat 2.
  defp scene_with_beat do
    scene = new_scene()
    open_with(scene, ["alice", "bram", "cara"])
    commit(scene, "alice", 2, "#{scene}-2-alice", "alice")
    commit(scene, "bram", 2, "#{scene}-2-bram", "bram")
    commit(scene, "cara", 2, "#{scene}-2-cara", "cara")
    scene
  end

  test "re-rolling a turn supersedes it and every later turn in the beat, not the earlier ones" do
    scene = scene_with_beat()

    assert {:ok, result} = Reroll.reroll(scene, 2, "bram", provider: Mock)

    # The tail from bram — bram and cara — was superseded; alice was not.
    assert result.superseded == ["#{scene}-2-bram", "#{scene}-2-cara"]
    assert superseded_markers(scene) == ["#{scene}-2-bram", "#{scene}-2-cara"]
    assert result.results == [{"bram", :ok}, {"cara", :ok}]

    ids = scene |> canonical() |> packet_ids()
    # Alice's original packet survives untouched; bram/cara are replaced by r1.
    assert "#{scene}-2-alice" in ids
    assert "#{scene}-2-bram-r1" in ids
    assert "#{scene}-2-cara-r1" in ids
    refute "#{scene}-2-bram" in ids
    refute "#{scene}-2-cara" in ids
  end

  test "a re-rolled turn is gone from every projection — even the omniscient one (§7)" do
    scene = scene_with_beat()
    {:ok, _} = Reroll.reroll(scene, 2, "bram", provider: Mock)

    events = canonical(scene)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    omniscient = Visibility.project(events, :omniscient, member_at?)

    # The superseded take never happened: not even the omniscient user replays it.
    refute Enum.any?(omniscient, &match?(%ThoughtOccurred{content: "bram-thought"}, &1))
    # Alice's untouched turn is still there.
    assert Enum.any?(omniscient, &match?(%ThoughtOccurred{content: "alice-thought"}, &1))
  end

  test "the dramatic-irony guarantee still holds for the regenerated packet" do
    scene = scene_with_beat()
    {:ok, _} = Reroll.reroll(scene, 2, "bram", provider: Mock)

    events = canonical(scene)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    cara_view = Visibility.project(events, {:character, "cara"}, member_at?)

    # Cara hears bram's regenerated line but never sees bram's interior — the core
    # guarantee is structural, so it survives a re-roll unchanged.
    assert Enum.any?(cara_view, &match?(%SpeechUttered{speaker_id: "bram"}, &1))

    refute Enum.any?(cara_view, fn e ->
             match?(%ThoughtOccurred{character_id: "bram"}, e)
           end)
  end

  test "re-rolling again increments the attempt and supersedes the previous re-roll" do
    scene = scene_with_beat()
    {:ok, _} = Reroll.reroll(scene, 2, "bram", provider: Mock)
    {:ok, _} = Reroll.reroll(scene, 2, "bram", provider: Mock)

    ids = scene |> canonical() |> packet_ids()
    assert "#{scene}-2-bram-r2" in ids
    refute "#{scene}-2-bram-r1" in ids

    # Exactly one canonical thought remains for bram — not a pile of attempts.
    bram_thoughts =
      scene |> canonical() |> Enum.count(&match?(%ThoughtOccurred{character_id: "bram"}, &1))

    assert bram_thoughts == 1
  end

  test "re-rolling anything but the latest beat is refused — that's a fork" do
    scene = new_scene()
    open_with(scene, ["alice"])
    commit(scene, "alice", 2, "#{scene}-2-alice", "a2")
    commit(scene, "alice", 3, "#{scene}-3-alice", "a3")

    assert {:error, :not_latest_beat} = Reroll.reroll(scene, 2, "alice", provider: Mock)
  end

  test "re-rolling a character with no packet in the beat is not found" do
    scene = scene_with_beat()
    assert {:error, :packet_not_found} = Reroll.reroll(scene, 2, "nobody", provider: Mock)
  end
end
