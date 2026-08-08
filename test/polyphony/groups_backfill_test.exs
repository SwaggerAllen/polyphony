defmodule Polyphony.GroupsBackfillTest do
  @moduledoc """
  STR-68: giving every existing group the campaign it belongs to.

  This runs once, unattended, over a live table, and the two ways it could be wrong are
  not symmetrical. Filing a group under the **wrong** campaign puts somebody's writing
  inside a story it was never part of, where it looks like it belongs — the one error
  here that doesn't announce itself. Trashing one is recoverable: it lands on the trash
  shelf with the ordinary window, one Restore away.

  So every case is either "assigns the right campaign" or "trashes it", and none of them
  is "assigns its best guess". A group belonging to no campaign is not a state that
  survives this pass, because it is not a state the app supports: it appears on no hub,
  which makes it unreachable from the story it was written for.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Groups, Library, Owner, Repo}
  alias Polyphony.Authoring.{CharacterSheet, Group}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{owner: Owner.user("u#{System.unique_integer([:positive])}")}
  end

  defp campaign(owner, attrs) do
    Library.put(%{
      owner: owner,
      kind: "campaign",
      payload: Map.merge(%{kind: :campaign, name: "Camp", character_ids: [], scenes: []}, attrs)
    })
  end

  defp world(owner, name) do
    Library.put(%{owner: owner, kind: "world_bible", payload: %{kind: :world, name: name}})
  end

  defp character(owner, name) do
    Library.put(%{owner: owner, kind: "character", payload: %CharacterSheet{name: name}})
  end

  # A group as it exists *before* the field — no `campaign_id`, which is what every
  # stored row looks like until this runs.
  #
  # Written straight to the library rather than through `Groups.create/3`, which now
  # refuses one: the state this migration exists to clear up is one the app can no
  # longer produce, so the only way to test the migration is to forge it.
  defp legacy_group(owner, attrs) do
    Library.put(%{
      owner: owner,
      kind: Group.kind(),
      payload: struct(Group, Map.merge(%{name: "The Tidewatch"}, attrs))
    })
  end

  defp campaign_id_of(entry),
    do: Library.get(entry.id) |> Library.payload() |> Map.get(:campaign_id)

  # Trashed, not purged — recoverable from the trash shelf on the ordinary clock.
  defp trashed?(entry), do: Library.get(entry.id).deleted_at != nil

  describe "by world" do
    test "a group written in a campaign lands on that campaign" do
      owner = Owner.user("u1")
      bible = world(owner, "The Ninth Gate")
      camp = campaign(owner, %{bible_id: bible.id})
      group = legacy_group(owner, %{world_bible_id: bible.id})

      assert %{placed: [%{id: id, campaign_id: cid}], trashed: []} = Groups.backfill_campaigns([])
      assert id == group.id
      assert cid == camp.id
      assert campaign_id_of(group) == camp.id
    end

    test "a world no campaign holds resolves nothing on its own" do
      # The library template — the case the world key could never answer, and the
      # reported bug. With no members either there is nothing left to go on, so the row
      # goes rather than becoming a group that belongs nowhere.
      owner = Owner.user("u2")
      template = world(owner, "A shared setting")
      group = legacy_group(owner, %{world_bible_id: template.id})

      assert %{placed: [], trashed: [id]} = Groups.backfill_campaigns([])
      assert id == group.id
      assert trashed?(group)
    end
  end

  describe "by members" do
    test "a library-written group lands where its people are" do
      # The recovery the world key can't do. The library shelf has always shown this
      # group under its members' campaign; backfilling on the world alone would have
      # moved it into the orphan band — a migration undoing information the app was
      # already displaying correctly.
      owner = Owner.user("u3")
      template = world(owner, "A shared setting")
      wren = character(owner, "Wren")
      camp = campaign(owner, %{character_ids: [wren.id]})

      group =
        legacy_group(owner, %{world_bible_id: template.id, member_ids: [to_string(wren.id)]})

      assert %{placed: [%{campaign_id: cid}], trashed: []} = Groups.backfill_campaigns([])
      assert cid == camp.id
      assert campaign_id_of(group) == camp.id
    end

    test "a member on no campaign is not an answer" do
      owner = Owner.user("u4")
      stray = character(owner, "Nobody's")
      group = legacy_group(owner, %{member_ids: [to_string(stray.id)]})

      assert %{placed: [], trashed: [_]} = Groups.backfill_campaigns([])
      assert trashed?(group)
    end
  end

  describe "what it refuses to do" do
    test "a group with nothing to go on is trashed, not kept as an orphan" do
      owner = Owner.user("u5")
      _camp = campaign(owner, %{})
      group = legacy_group(owner, %{})

      assert %{placed: [], trashed: [_]} = Groups.backfill_campaigns([])
      assert trashed?(group)

      # And the shelf no longer carries it, which is the point: the class stops
      # existing rather than becoming a heading to file things under.
      assert Groups.orphans(owner) == []
      assert Groups.list(owner) == []
    end

    test "it never files a group under somebody else's campaign" do
      # Library ids come from one sequence so this shouldn't be reachable — which is
      # exactly why the check is here rather than assumed, in the one pass that
      # rewrites every row with nobody watching.
      mine = Owner.user("mine")
      theirs = Owner.user("theirs")
      bible = world(theirs, "Not yours")
      _their_camp = campaign(theirs, %{bible_id: bible.id})
      group = legacy_group(mine, %{world_bible_id: bible.id})

      assert %{placed: [], trashed: [_]} = Groups.backfill_campaigns([])
      assert trashed?(group)
    end

    test "it leaves a group that already has a campaign alone" do
      owner = Owner.user("u6")
      bible = world(owner, "The Ninth Gate")
      _camp = campaign(owner, %{bible_id: bible.id})
      other = campaign(owner, %{name: "Elsewhere"})
      group = legacy_group(owner, %{world_bible_id: bible.id, campaign_id: other.id})

      assert %{placed: [], trashed: []} = Groups.backfill_campaigns([])
      assert campaign_id_of(group) == other.id
    end

    test "a published snapshot is not a campaign to file anybody under" do
      # A snapshot is `kind: "campaign"` and frozen, and its payload is a `Snapshot`
      # rather than a live roster. Counting one would file a group inside a frozen copy
      # of a story, which nobody can edit.
      owner = Owner.user("u7")
      wren = character(owner, "Wren")

      Library.put(%{
        owner: owner,
        kind: "campaign",
        frozen: true,
        payload: %{kind: :campaign, name: "Published", character_ids: [wren.id], scenes: []}
      })

      group = legacy_group(owner, %{member_ids: [to_string(wren.id)]})

      assert %{placed: [], trashed: [_]} = Groups.backfill_campaigns([])
      assert trashed?(group)
    end
  end

  test "it is safe to run twice" do
    # Migrations get re-run — a redeploy, a restored database, `MIGRATE_ON_BOOT`. The
    # second pass must find nothing to do rather than doing it again.
    owner = Owner.user("u8")
    bible = world(owner, "The Ninth Gate")
    camp = campaign(owner, %{bible_id: bible.id})
    group = legacy_group(owner, %{world_bible_id: bible.id})

    assert %{placed: [_], trashed: []} = Groups.backfill_campaigns([])
    assert %{placed: [], trashed: []} = Groups.backfill_campaigns([])
    assert campaign_id_of(group) == camp.id
  end

  test "a stored group predating the field reads as nil rather than raising" do
    # The hazard the field being added to a live table creates: a payload written
    # before `campaign_id` decodes *without the key*, so reading it as `group.campaign_id`
    # raises `KeyError` on every row until the backfill runs.
    owner = Owner.user("u9")
    group = legacy_group(owner, %{})
    stored = group.id |> Library.get() |> Library.payload()

    assert Map.get(stored, :campaign_id) == nil
    assert %Group{campaign_id: nil} = Group.load(stored)
  end
end
