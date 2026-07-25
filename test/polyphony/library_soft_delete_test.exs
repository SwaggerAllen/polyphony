defmodule Polyphony.LibrarySoftDeleteTest do
  @moduledoc """
  §B9: soft-delete. Archive hides from default lists but is recoverable; delete is a
  recoverable tombstone that unpublishes published content; purge is the hard, final
  destruction. Forks are independent copies and never cascade.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp entry(owner \\ "u1", attrs \\ %{}) do
    Library.put(Map.merge(%{owner_id: owner, kind: "character", payload: %{n: 1}}, attrs))
  end

  describe "archive (recoverable, hidden from default lists)" do
    test "archived entries drop from the owner list but come back when opted in or restored" do
      e = entry()
      assert {:ok, _} = Library.archive(e.id)

      assert Library.list_for_owner("u1") == []
      assert [_] = Library.list_for_owner("u1", include_archived: true)
      refute Library.live?(Library.get(e.id))

      assert {:ok, _} = Library.unarchive(e.id)
      assert [_] = Library.list_for_owner("u1")
      assert Library.live?(Library.get(e.id))
    end
  end

  describe "soft-delete (recoverable tombstone)" do
    test "delete hides the entry and unpublishes published content" do
      e = entry("u1", %{visibility: "public"})
      assert {:ok, deleted} = Library.soft_delete(e.id)

      # Resolved snapshot: no longer publicly reachable.
      assert deleted.visibility == "private"
      assert Library.list_for_owner("u1") == []
      assert Library.list_public("character") == []
      refute Library.live?(Library.get(e.id))
    end

    test "restore brings a soft-deleted entry back within the recovery window" do
      e = entry()
      {:ok, _} = Library.soft_delete(e.id)
      assert {:ok, _} = Library.restore(e.id)
      assert [_] = Library.list_for_owner("u1")
      assert Library.live?(Library.get(e.id))
    end
  end

  describe "purge (hard, final)" do
    test "purge removes the row entirely" do
      e = entry()
      assert {:ok, _} = Library.purge(e.id)
      assert Library.get(e.id) == nil
    end
  end

  describe "forks survive independently (no cascade)" do
    test "deleting a published campaign does not touch a prior fork's re-owned copies" do
      published =
        Library.publish_campaign(%{
          owner_id: "author",
          campaign_id: "camp",
          published_beat: 1,
          bible: %Polyphony.Authoring.WorldBible{name: "W"},
          characters: [%{source_id: 1, source_version: 1, sheet: %{n: 1}}],
          arc: []
        })

      %{campaign: forked, characters: [char_copy]} = Library.fork_campaign(published, "forker")

      # Delete (and purge) the published source.
      {:ok, _} = Library.soft_delete(published.id)
      {:ok, _} = Library.purge(published.id)

      # The fork and its re-owned character copy are untouched — independent copies.
      assert Library.live?(Library.get(forked.id))
      assert Library.live?(Library.get(char_copy.id))
      assert [_] = Library.list_for_owner("forker") |> Enum.filter(&(&1.kind == "campaign"))
    end
  end
end
