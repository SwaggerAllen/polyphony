defmodule Polyphony.PacketsTest do
  @moduledoc "The canonical-view filter that hides re-rolled packets (§7)."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias PolyphonyCore.Packets

  describe "canonical/1" do
    test "drops superseded packets and the markers themselves" do
      events = [
        thought("mira", "S1", 2, "first take", packet_id: "S1-2-mira"),
        speech("mira", "S1", 2, "first line", packet_id: "S1-2-mira"),
        superseded("S1", "mira", 2, "S1-2-mira", attempt: 1),
        thought("mira", "S1", 2, "second take", packet_id: "S1-2-mira-r1"),
        speech("mira", "S1", 2, "second line", packet_id: "S1-2-mira-r1")
      ]

      canonical = Packets.canonical(events)

      contents = Enum.map(canonical, &Map.get(&1, :content))
      assert "second take" in contents
      assert "second line" in contents
      refute "first take" in contents
      refute "first line" in contents

      refute Enum.any?(canonical, &match?(%PolyphonyCore.Events.PacketSuperseded{}, &1))
    end

    test "leaves packets that were never superseded untouched, in order" do
      events = [
        entered("S1", "alice", 1),
        action("alice", "S1", 2, "opens the door", packet_id: "S1-2-alice"),
        speech("bram", "S1", 2, "after you", packet_id: "S1-2-bram")
      ]

      assert Packets.canonical(events) == events
    end

    test "a packet superseded twice stays gone through both re-rolls" do
      events = [
        thought("x", "S", 1, "v0", packet_id: "S-1-x"),
        superseded("S", "x", 1, "S-1-x", attempt: 1),
        thought("x", "S", 1, "v1", packet_id: "S-1-x-r1"),
        superseded("S", "x", 1, "S-1-x-r1", attempt: 2),
        thought("x", "S", 1, "v2", packet_id: "S-1-x-r2")
      ]

      assert Packets.canonical(events) |> Enum.map(& &1.content) == ["v2"]
    end
  end

  describe "beat_packets/2 (cast order)" do
    test "returns one entry per packet in first-appearance order" do
      events = [
        thought("alice", "S", 2, "a", packet_id: "S-2-alice"),
        speech("alice", "S", 2, "a!", packet_id: "S-2-alice"),
        speech("bram", "S", 2, "b!", packet_id: "S-2-bram"),
        action("cara", "S", 2, "c", packet_id: "S-2-cara")
      ]

      assert Packets.beat_packets(events, 2) == [
               {"alice", "S-2-alice"},
               {"bram", "S-2-bram"},
               {"cara", "S-2-cara"}
             ]
    end

    test "ignores other beats" do
      events = [
        action("alice", "S", 2, "c", packet_id: "S-2-alice"),
        action("alice", "S", 3, "c", packet_id: "S-3-alice")
      ]

      assert Packets.beat_packets(events, 3) == [{"alice", "S-3-alice"}]
    end
  end

  describe "latest_beat/1" do
    test "is the highest beat carrying a packet" do
      events = [
        entered("S", "alice", 5),
        action("alice", "S", 2, "c", packet_id: "S-2-alice"),
        action("alice", "S", 4, "c", packet_id: "S-4-alice")
      ]

      assert Packets.latest_beat(events) == 4
    end

    test "is nil with no packets" do
      assert Packets.latest_beat([entered("S", "alice", 1)]) == nil
    end
  end
end
