defmodule Polyphony.BroadcastTest do
  @moduledoc "The per-viewer fan-out (§13) — pure routing and message shaping."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias Polyphony.Broadcast
  alias PolyphonyCore.MembershipSet
  alias PolyphonyCore.Events.{BeatOpened, BeatClosed}

  # a,b present in S1; c not.
  defp member_at? do
    [entered("S1", "a", 1), entered("S1", "b", 1)]
    |> MembershipSet.from_events()
    |> MembershipSet.member_at_fun()
  end

  defp viewers(pairs), do: pairs |> Enum.map(fn {_topic, m} -> m.viewer end) |> Enum.sort()

  test "topics are per (scene, viewer)" do
    assert Broadcast.topic("S1", :omniscient) == "scene:S1:omniscient"
    assert Broadcast.topic("S1", {:character, "mira"}) == "scene:S1:character:mira"
  end

  test "an interior thought fans out only to the omniscient viewer and its owner" do
    event = thought("a", "S1", 2, "secret")
    pairs = Broadcast.fan_out("S1", event, 5, ["a", "b"], member_at?())
    assert viewers(pairs) == ["character:a", "omniscient"]
  end

  test "a whisper reaches the speaker and addressees only" do
    event = speech("a", "S1", 2, "psst", addressed_to: ["b"], audibility: :private)
    pairs = Broadcast.fan_out("S1", event, 6, ["a", "b", "c"], member_at?())
    assert viewers(pairs) == ["character:a", "character:b", "omniscient"]
  end

  test "a normal scene event reaches the omniscient viewer and members at the beat" do
    event = speech("a", "S1", 2, "hello")
    pairs = Broadcast.fan_out("S1", event, 7, ["a", "b", "c"], member_at?())
    # c is not a member at beat 2, so c's topic is not published.
    assert viewers(pairs) == ["character:a", "character:b", "omniscient"]
  end

  test "beat/lifecycle events reach only the omniscient viewer" do
    # A ThoughtOccurred is interior; a SceneOpened is default-deny for characters.
    pairs = Broadcast.fan_out("S1", scene_opened("S1", 0), 1, ["a", "b"], member_at?())
    assert viewers(pairs) == ["omniscient"]
  end

  test "the message carries type, seq, kind, and payload" do
    [{_topic, msg} | _] =
      Broadcast.fan_out("S1", speech("a", "S1", 2, "hi"), 9, ["a"], member_at?())

    assert msg.type == "event.committed"
    assert msg.seq == 9
    assert msg.kind == "SpeechUttered"
    assert msg.payload.content == "hi"
  end

  describe "beat framing → omniscient only" do
    test "BeatOpened becomes a beat.opened framing message" do
      e = %BeatOpened{beat_ref: "S1-b2", scene_id: "S1", beat: 2, cast: ["a", "b"]}
      assert [{topic, msg}] = Broadcast.fan_out("S1", e, nil, ["a", "b"], member_at?())
      assert topic == Broadcast.topic("S1", :omniscient)

      assert msg == %{
               type: "beat.opened",
               viewer: "omniscient",
               scene_id: "S1",
               beat: 2,
               cast: ["a", "b"]
             }
    end

    test "BeatClosed becomes a beat.closed framing message carrying the failure list" do
      e = %BeatClosed{
        beat_ref: "S1-b2",
        scene_id: "S1",
        beat: 2,
        completed: ["a"],
        failed: [%{character_id: "b", reason: "timeout"}]
      }

      assert [{_topic, msg}] = Broadcast.fan_out("S1", e, nil, [], member_at?())
      assert msg.type == "beat.closed"
      assert msg.failed == [%{character_id: "b", reason: "timeout"}]
    end
  end

  describe "re-roll eviction framing (§7)" do
    test "packet.superseded reaches the omniscient user, the packet's owner, and members at the beat" do
      e = superseded("S1", "a", 2, "S1-2-a", attempt: 1)
      pairs = Broadcast.fan_out("S1", e, nil, ["a", "b", "c"], member_at?())

      # a is the owner; a and b are members at beat 2; c is not a member.
      assert viewers(pairs) == ["character:a", "character:b", "omniscient"]

      assert [{_topic, msg} | _] = pairs
      assert msg.type == "packet.superseded"
      assert msg.packet_id == "S1-2-a"
      assert msg.character_id == "a"
    end

    test "a reconnecting client never replays a superseded packet" do
      events = [
        {1, thought("a", "S1", 2, "first take", packet_id: "S1-2-a")},
        {2, speech("a", "S1", 2, "first line", packet_id: "S1-2-a")},
        {3, superseded("S1", "a", 2, "S1-2-a", attempt: 1)},
        {4, thought("a", "S1", 2, "second take", packet_id: "S1-2-a-r1")}
      ]

      msgs = Broadcast.replay(events, :omniscient, member_at?(), 0)
      contents = Enum.map(msgs, &Map.get(&1.payload, :content))

      assert "second take" in contents
      refute "first take" in contents
      refute "first line" in contents
      refute Enum.any?(msgs, &(&1.kind == "PacketSuperseded"))
    end
  end

  describe "replay (reconnection cursor)" do
    test "returns only events past the cursor that are visible to the viewer" do
      events = [
        {1, thought("a", "S1", 2, "a-thought")},
        {2, speech("a", "S1", 2, "a-speech")},
        {3, thought("b", "S1", 2, "b-thought")}
      ]

      msgs = Broadcast.replay(events, {:character, "b"}, member_at?(), 0)
      kinds = Enum.map(msgs, & &1.kind)

      # b sees a's speech and b's own thought; never a's thought.
      assert "SpeechUttered" in kinds
      assert "ThoughtOccurred" in kinds
      refute Enum.any?(msgs, &(&1.kind == "ThoughtOccurred" and &1.payload.character_id == "a"))
    end

    test "honors the from_seq cursor" do
      events = [{1, speech("a", "S1", 2, "old")}, {2, speech("a", "S1", 2, "new")}]
      msgs = Broadcast.replay(events, :omniscient, member_at?(), 1)
      assert Enum.map(msgs, & &1.payload.content) == ["new"]
    end
  end
end
