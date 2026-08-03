defmodule Polyphony.ReadModels.MembershipTest do
  @moduledoc """
  Parity test (§8): the Postgres interval read model must answer membership
  *identically* to the pure `MembershipSet`. If these two ever diverge, a
  character's context and the visibility predicate would disagree — the exact
  seam where irony would leak. So we drive the same event scenario through both
  and compare `member_at?` across an exhaustive grid.
  """
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario

  alias Polyphony.Repo
  alias Polyphony.MembershipSet
  alias Polyphony.ReadModels.Membership
  alias Polyphony.Events.{CharacterEntered, CharacterExited}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # Replay membership events into Postgres exactly as the projector would.
  defp replay!(events) do
    Enum.each(events, fn
      %CharacterEntered{} = e -> Membership.enter(Repo, e.scene_id, e.character_id, e.beat)
      %CharacterExited{} = e -> Membership.leave(Repo, e.scene_id, e.character_id, e.beat)
      _ -> :ok
    end)
  end

  @scenario [
    entered("S1", "A", 1),
    entered("S1", "B", 1),
    entered("S1", "D", 1),
    entered("S2", "C", 1),
    exited("S1", "D", 4),
    entered("S1", "D", 8),
    exited("S1", "A", 10)
  ]

  test "Postgres member_at? matches MembershipSet across the whole grid" do
    replay!(@scenario)
    set = MembershipSet.from_events(@scenario)

    scenes = ["S1", "S2"]
    chars = ["A", "B", "C", "D"]
    beats = 0..12

    for scene <- scenes, char <- chars, beat <- beats do
      db = Membership.member_at?(Repo, scene, char, beat)
      pure = MembershipSet.member_at?(set, scene, char, beat)

      assert db == pure,
             "mismatch at #{scene}/#{char}@#{beat}: db=#{db} pure=#{pure}"
    end
  end

  test "re-entry produces two rows and the gap excludes the middle" do
    replay!([entered("S1", "D", 1), exited("S1", "D", 4), entered("S1", "D", 8)])

    refute Membership.member_at?(Repo, "S1", "D", 5), "in the gap"
    assert Membership.member_at?(Repo, "S1", "D", 2), "first interval"
    assert Membership.member_at?(Repo, "S1", "D", 9), "second interval"
  end

  test "members_at returns everyone present at a beat" do
    replay!(@scenario)

    assert Enum.sort(Membership.members_at(Repo, "S1", 2)) == ["A", "B", "D"]
    # D has left (exited at 4), A and B remain at beat 5.
    assert Enum.sort(Membership.members_at(Repo, "S1", 5)) == ["A", "B"]
    # D re-entered at 8, A leaves at 10.
    assert Enum.sort(Membership.members_at(Repo, "S1", 9)) == ["A", "B", "D"]
    assert Enum.sort(Membership.members_at(Repo, "S1", 11)) == ["B", "D"]
  end

  describe "a character's scenes (§2.14 — \"In 3 scenes\" on their sheet)" do
    test "counts scenes, not doorways: leaving and coming back is still one scene" do
      replay!([entered("S1", "D", 1), exited("S1", "D", 4), entered("S1", "D", 8)])

      assert Membership.scenes_for_character(Repo, "D") == ["S1"]
      assert Membership.scene_count(Repo, "D") == 1
    end

    test "lists every scene a character has been in, in first-entry order" do
      replay!([
        entered("S2", "A", 3),
        entered("S1", "A", 1),
        entered("S3", "A", 7),
        entered("S1", "B", 1)
      ])

      assert Membership.scenes_for_character(Repo, "A") == ["S1", "S2", "S3"]
      assert Membership.scene_count(Repo, "A") == 3
    end

    test "someone else's scenes are not counted" do
      replay!(@scenario)

      assert Membership.scenes_for_character(Repo, "C") == ["S2"]
      assert Membership.scene_count(Repo, "B") == 1
    end

    test "a character who has never played is zero, not an error" do
      assert Membership.scenes_for_character(Repo, "nobody") == []
      assert Membership.scene_count(Repo, "nobody") == 0
    end
  end
end
