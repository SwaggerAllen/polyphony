defmodule Polyphony.GroupsBackfillTest do
  @moduledoc """
  STR-68: giving every existing group the campaign it belongs to.

  This runs once, unattended, over a live table, and the two ways it could be wrong are
  not symmetrical. Filing a group under **no** campaign is recoverable — it sits on the
  library shelf, visibly unplaced, one delete or one re-file away. Filing it under the
  **wrong** campaign puts somebody's writing inside a story it was never part of, where
  it looks like it belongs. So every case here is either "assigns the right one" or
  "assigns none", and none of them is "assigns its best guess".
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

  # A group as it exists *before* the field — no `campaign_id` at all, which is what
  # every stored row looks like until this runs.
  defp legacy_group(owner, attrs) do
    Groups.create(owner, struct(Group, Map.merge(%{name: "The Tidewatch"}, attrs)))
  end

  defp campaign_id_of(entry),
    do: Library.get(entry.id) |> Library.payload() |> Map.get(:campaign_id)

  describe "by world" do
    test "a group written in a campaign lands on that campaign" do
      owner = Owner.user("u1")
      bible = world(owner, "The Ninth Gate")
      camp = campaign(owner, %{bible_id: bible.id})
      group = legacy_group(owner, %{world_bible_id: bible.id})

      assert [%{id: id, campaign_id: cid}] = Groups.backfill_campaigns([])
      assert id == group.id
      assert cid == camp.id
      assert campaign_id_of(group) == camp.id
    end

    test "a world no campaign holds resolves nothing on its own" do
      # The library template — the case the world key could never answer, and the
      # reported bug. With no members either, this stays an orphan.
      owner = Owner.user("u2")
      template = world(owner, "A shared setting")
      group = legacy_group(owner, %{world_bible_id: template.id})

      assert Groups.backfill_campaigns([]) == []
      assert campaign_id_of(group) == nil
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

      assert [%{campaign_id: cid}] = Groups.backfill_campaigns([])
      assert cid == camp.id
      assert campaign_id_of(group) == camp.id
    end

    test "a member on no campaign is not an answer" do
      owner = Owner.user("u4")
      stray = character(owner, "Nobody's")
      group = legacy_group(owner, %{member_ids: [to_string(stray.id)]})

      assert Groups.backfill_campaigns([]) == []
      assert campaign_id_of(group) == nil
    end
  end

  describe "what it refuses to do" do
    test "a group with nothing to go on stays unplaced" do
      owner = Owner.user("u5")
      _camp = campaign(owner, %{})
      group = legacy_group(owner, %{})

      assert Groups.backfill_campaigns([]) == []
      assert campaign_id_of(group) == nil
      # And it is reachable, which is the whole reason not to guess.
      assert [%{id: id}] = Groups.orphans(owner)
      assert id == group.id
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

      assert Groups.backfill_campaigns([]) == []
      assert campaign_id_of(group) == nil
    end

    test "it leaves a group that already has a campaign alone" do
      owner = Owner.user("u6")
      bible = world(owner, "The Ninth Gate")
      _camp = campaign(owner, %{bible_id: bible.id})
      other = campaign(owner, %{name: "Elsewhere"})
      group = legacy_group(owner, %{world_bible_id: bible.id, campaign_id: other.id})

      assert Groups.backfill_campaigns([]) == []
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

      assert Groups.backfill_campaigns([]) == []
      assert campaign_id_of(group) == nil
    end
  end

  test "it is safe to run twice" do
    # Migrations get re-run — a redeploy, a restored database, `MIGRATE_ON_BOOT`. The
    # second pass must find nothing to do rather than doing it again.
    owner = Owner.user("u8")
    bible = world(owner, "The Ninth Gate")
    camp = campaign(owner, %{bible_id: bible.id})
    group = legacy_group(owner, %{world_bible_id: bible.id})

    assert [_] = Groups.backfill_campaigns([])
    assert Groups.backfill_campaigns([]) == []
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
