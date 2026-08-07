defmodule Polyphony.LibraryShelfTest do
  @moduledoc """
  What the library screen needs the domain to be able to say
  (`ux/polyphony-library.html`).

  Two things, and the second is the one that had been a promise:

    * **A campaign says where it is.** Not started, playing, finished — and *finished*
      is a statement rather than filing (§2.5c). Archiving means "out of the way";
      concluding means "this story is over", which is what another campaign names when
      it calls this one a prequel.
    * **The recovery window is a number, not a claim** (§2.13). `Library` had
      `soft_delete`, `restore` and `purge`, and nothing that ever called the last one —
      so "deleted things wait 30 days" had nothing behind it and the trash row's
      countdown would have counted down to a day that never came.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Campaigns, Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{ArcEntry, CharacterSheet, WorldArcEntry, WorldBible}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp campaign(owner, attrs \\ %{}) do
    payload =
      Map.merge(%{kind: :campaign, name: "The Salt Line", character_ids: [], scenes: []}, attrs)

    Library.put(%{owner: owner, kind: "campaign", payload: payload})
  end

  defp character(owner, name),
    do: Library.put(%{owner: owner, kind: "character", payload: %CharacterSheet{name: name}})

  describe "where a campaign is" do
    test "made and never opened reads as not started" do
      entry = campaign(owner())
      assert Campaigns.status(Library.payload(entry)) == :unstarted
      assert Campaigns.status_label(:unstarted) == "Not started"
    end

    test "scenes make it playing, derived rather than remembered" do
      entry = campaign(owner(), %{scenes: ["S1"]})
      assert Campaigns.status(Library.payload(entry)) == :playing
    end

    test "finishing is a statement, and doesn't file it away" do
      owner = owner()
      entry = campaign(owner, %{scenes: ["S1"]})

      {:ok, _} = Campaigns.finish(entry.id)

      finished = Library.get(entry.id)
      assert Campaigns.status(Library.payload(finished)) == :finished
      # Still in the library — a finished campaign is the one you most want to find.
      assert Enum.any?(Campaigns.list(owner), &(&1.id == entry.id))
      assert finished.archived_at == nil
    end

    test "and it's reversible, because concluding something is a judgement" do
      entry = campaign(owner(), %{scenes: ["S1"]})
      {:ok, _} = Campaigns.finish(entry.id)
      {:ok, _} = Campaigns.reopen(entry.id)

      assert Campaigns.status(Library.payload(Library.get(entry.id))) == :playing
    end

    test "archiving is the other thing, and says nothing about the story" do
      owner = owner()
      entry = campaign(owner, %{scenes: ["S1"]})

      {:ok, _} = Library.archive(entry.id)

      refute Enum.any?(Campaigns.list(owner), &(&1.id == entry.id))
      assert Enum.any?(Library.archived(owner), &(&1.id == entry.id))
      # Filed, not concluded.
      assert Campaigns.status(Library.payload(Library.get(entry.id))) == :playing
    end
  end

  describe "what's waiting on a campaign" do
    test "counts its cast's proposals and its world's together" do
      owner = owner()
      wren = character(owner, "Wren")
      ilias = character(owner, "Ilias")
      entry = campaign(owner, %{character_ids: [wren.id, ilias.id]})

      assert Campaigns.pending_review(entry) == 0

      ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "a"}, wren.id)
      ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "b"}, wren.id)
      ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "c"}, ilias.id)
      ArcRM.put_world(Repo, %WorldArcEntry{kind: :discovery, statement: "d"}, entry.id)

      # The same number the gate will stop them with, so the row doesn't surprise anyone.
      assert Campaigns.pending_review(entry) == 4
    end

    test "an accepted proposal stops counting" do
      owner = owner()
      wren = character(owner, "Wren")
      entry = campaign(owner, %{character_ids: [wren.id]})
      row = ArcRM.put(Repo, %ArcEntry{kind: :discovery, statement: "a"}, wren.id)

      ArcRM.accept(Repo, row.id)
      assert Campaigns.pending_review(entry) == 0
    end
  end

  describe "characters belong to exactly one campaign" do
    test "which is what makes the library's grouping free" do
      owner = owner()
      wren = character(owner, "Wren")
      rusk = character(owner, "Bellwether Rusk")
      loose = character(owner, "Nobody's yet")

      salt = campaign(owner, %{name: "The Salt Line", character_ids: [wren.id]})
      low = campaign(owner, %{name: "Low Water", character_ids: [rusk.id]})

      by = Campaigns.by_character(owner)

      assert by[to_string(wren.id)].id == salt.id
      assert by[to_string(rusk.id)].id == low.id
      # Someone in no campaign yet maps to nothing; the caller decides where to put them.
      refute Map.has_key?(by, to_string(loose.id))
    end
  end

  describe "the recovery window" do
    test "a trashed entry counts down, and a live one has no countdown" do
      owner = owner()
      entry = campaign(owner)

      assert Library.days_until_purge(Library.get(entry.id)) == nil

      {:ok, _} = Library.soft_delete(entry.id)
      assert Library.days_until_purge(Library.get(entry.id)) == Library.retention_days()
    end

    test "it rounds up, so a day left never shows as none" do
      owner = owner()
      entry = campaign(owner)

      # Deleted 29 days and 1 hour ago: a sliver under a day remains.
      at = NaiveDateTime.add(NaiveDateTime.utc_now(), -(29 * 86_400 + 3600), :second)
      {:ok, _} = Library.soft_delete(entry.id, now: at)

      assert Library.days_until_purge(Library.get(entry.id)) == 1
    end

    test "and bottoms out at zero rather than going negative" do
      owner = owner()
      entry = campaign(owner)
      at = NaiveDateTime.add(NaiveDateTime.utc_now(), -100 * 86_400, :second)
      {:ok, _} = Library.soft_delete(entry.id, now: at)

      assert Library.days_until_purge(Library.get(entry.id)) == 0
    end

    test "trash and archive are different shelves" do
      owner = owner()
      filed = campaign(owner, %{name: "Filed"})
      binned = campaign(owner, %{name: "Binned"})

      {:ok, _} = Library.archive(filed.id)
      {:ok, _} = Library.soft_delete(binned.id)

      assert [%{id: id}] = Library.archived(owner)
      assert id == filed.id
      assert [%{id: other}] = Library.trash(owner)
      assert other == binned.id
    end

    test "purge_expired takes what's past the window and leaves what isn't" do
      owner = owner()
      old = campaign(owner, %{name: "Old"})
      recent = campaign(owner, %{name: "Recent"})
      live = campaign(owner, %{name: "Live"})

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400, :second)
      {:ok, _} = Library.soft_delete(old.id, now: long_ago)
      {:ok, _} = Library.soft_delete(recent.id)

      assert Library.purge_expired() == 1

      # Really gone — this is the half that makes the countdown a number rather than a claim.
      assert Library.get(old.id) == nil
      assert Library.get(recent.id) != nil
      assert Library.get(live.id) != nil
    end

    test "running it twice finds nothing the second time" do
      owner = owner()
      entry = campaign(owner)
      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -40 * 86_400, :second)
      {:ok, _} = Library.soft_delete(entry.id, now: long_ago)

      assert Library.purge_expired() == 1
      assert Library.purge_expired() == 0
    end

    test "restoring inside the window puts it back on the shelf" do
      owner = owner()
      entry = Library.put(%{owner: owner, kind: "world_bible", payload: %WorldBible{name: "X"}})

      {:ok, _} = Library.soft_delete(entry.id)
      {:ok, _} = Library.restore(entry.id)

      assert Library.trash(owner) == []
      assert Enum.any?(Library.list_for_owner(owner), &(&1.id == entry.id))
    end
  end
end
