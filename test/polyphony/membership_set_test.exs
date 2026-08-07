defmodule Polyphony.MembershipSetTest do
  @moduledoc "Interval semantics for the pure membership fold (§8)."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias PolyphonyCore.MembershipSet

  defp set(events), do: MembershipSet.from_events(events)

  test "half-open interval: entered_beat is inclusive, exited_beat is exclusive" do
    s = set([entered("S", "A", 2), exited("S", "A", 5)])

    refute MembershipSet.member_at?(s, "S", "A", 1)
    assert MembershipSet.member_at?(s, "S", "A", 2)
    assert MembershipSet.member_at?(s, "S", "A", 4)
    refute MembershipSet.member_at?(s, "S", "A", 5), "exit beat is not a member (half-open)"
    refute MembershipSet.member_at?(s, "S", "A", 6)
  end

  test "an open interval (no exit) extends indefinitely" do
    s = set([entered("S", "A", 3)])

    refute MembershipSet.member_at?(s, "S", "A", 2)
    assert MembershipSet.member_at?(s, "S", "A", 3)
    assert MembershipSet.member_at?(s, "S", "A", 9_999)
  end

  test "re-entry is a second interval with a gap that excludes the middle" do
    s =
      set([
        entered("S", "A", 1),
        exited("S", "A", 3),
        entered("S", "A", 7)
      ])

    assert MembershipSet.member_at?(s, "S", "A", 2), "present in first interval"
    refute MembershipSet.member_at?(s, "S", "A", 3), "gap begins at first exit"
    refute MembershipSet.member_at?(s, "S", "A", 6), "still in the gap"
    assert MembershipSet.member_at?(s, "S", "A", 7), "present again after re-entry"
    assert MembershipSet.member_at?(s, "S", "A", 100)
  end

  test "membership is scoped per (scene, character)" do
    s = set([entered("S1", "A", 1), entered("S2", "B", 1)])

    assert MembershipSet.member_at?(s, "S1", "A", 1)
    refute MembershipSet.member_at?(s, "S2", "A", 1)
    refute MembershipSet.member_at?(s, "S1", "B", 1)
    assert MembershipSet.member_at?(s, "S2", "B", 1)
  end

  test "a stray exit with no open interval is ignored, not a crash" do
    s = set([exited("S", "A", 5)])
    refute MembershipSet.member_at?(s, "S", "A", 5)
  end

  test "non-membership events are ignored by the fold" do
    s = set([speech("A", "S", 1, "hi"), thought("A", "S", 1, "hmm"), entered("S", "A", 1)])
    assert MembershipSet.member_at?(s, "S", "A", 1)
  end
end
