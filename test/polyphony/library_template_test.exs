defmodule Polyphony.LibraryTemplateTest do
  @moduledoc """
  A library world is a **template** (`completed-roadmap.md` §2.5b), plus the two small
  library affordances the world screen needs around it.

  The copy is forced by world arc: a campaign accumulates history onto its world, and
  two campaigns cannot write different pasts onto one bible. Everything the design
  claims follows from that, and each claim is a test here — editing the template
  reaches nobody already started, deleting it breaks nothing, and the only route back
  is deliberate and takes a snapshot rather than a link.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp world(owner, attrs \\ %{}),
    do:
      Library.put(%{
        owner: owner,
        kind: "world_bible",
        payload: struct(%WorldBible{name: "Saltmarch"}, attrs)
      })

  describe "copy/3" do
    test "carries the payload and points back at what it came from" do
      owner = owner()
      source = world(owner, %{tone: "Damp, close, quietly criminal."})

      copy = Library.copy(source, owner)

      refute copy.id == source.id
      assert copy.derived_from_id == source.id
      assert copy.derived_from_version == source.version
      assert Library.payload(copy).tone == "Damp, close, quietly criminal."
    end

    test "a copy is private and editable, whatever the source was" do
      owner = owner()
      source = world(owner)
      {:ok, _} = Library.set_visibility(source.id, :public)

      copy = Library.copy(Library.get(source.id), owner)

      assert copy.visibility == "private"
      refute copy.frozen
    end

    test "editing the template doesn't reach the copy, and editing the copy doesn't reach back" do
      owner = owner()
      source = world(owner, %{tone: "Damp"})
      copy = Library.copy(source, owner)

      {:ok, _} = Library.update_payload(source.id, %WorldBible{name: "Saltmarch", tone: "Dry"})
      assert Library.payload(Library.get(copy.id)).tone == "Damp"

      {:ok, _} = Library.update_payload(copy.id, %WorldBible{name: "Saltmarch", tone: "Frozen"})
      assert Library.payload(Library.get(source.id)).tone == "Dry"
    end

    test "deleting the template can't break a campaign that started from it" do
      owner = owner()
      source = world(owner, %{tone: "Damp"})
      copy = Library.copy(source, owner)

      {:ok, _} = Library.soft_delete(source.id)

      assert Library.payload(Library.get(copy.id)).tone == "Damp"
    end

    test "the way back is a copy in the other direction — a snapshot, not a link" do
      owner = owner()
      template = world(owner, %{tone: "Damp"})
      campaign_copy = Library.copy(template, owner)

      {:ok, _} =
        Library.update_payload(campaign_copy.id, %WorldBible{name: "Saltmarch", tone: "Weathered"})

      saved = Library.copy(Library.get(campaign_copy.id), owner)

      assert Library.payload(saved).tone == "Weathered"
      assert saved.derived_from_id == campaign_copy.id
      # Still a snapshot: later campaign edits don't reach the library entry.
      {:ok, _} =
        Library.update_payload(campaign_copy.id, %WorldBible{name: "Saltmarch", tone: "Gone"})

      assert Library.payload(Library.get(saved.id)).tone == "Weathered"
    end
  end

  describe "copies_of / copy_count" do
    test "counts what \"used in 2 campaigns\" means" do
      owner = owner()
      source = world(owner)

      assert Library.copy_count(source.id) == 0

      Library.copy(source, owner)
      Library.copy(source, owner)

      assert Library.copy_count(source.id) == 2
      assert Enum.all?(Library.copies_of(source.id), &(&1.derived_from_id == source.id))
    end

    test "a deleted copy stops counting" do
      owner = owner()
      source = world(owner)
      copy = Library.copy(source, owner)

      {:ok, _} = Library.soft_delete(copy.id)

      assert Library.copy_count(source.id) == 0
    end
  end

  describe "rotate_share_token/2" do
    test "a new link breaks the old one — which is the point of the control" do
      owner = owner()
      entry = world(owner)
      {:ok, shared} = Library.set_visibility(entry.id, :unlisted)
      old = shared.share_token

      assert Library.get_by_share_token(old).id == entry.id

      {:ok, rotated} = Library.rotate_share_token(entry.id)

      refute rotated.share_token == old
      assert Library.get_by_share_token(old) == nil
      assert Library.get_by_share_token(rotated.share_token).id == entry.id
    end

    test "rotating something that isn't there is an error, not a new token" do
      assert {:error, :not_found} = Library.rotate_share_token(2_147_483_000)
    end
  end

  describe "name_taken?/4" do
    test "catches the repeat the design catches at the field" do
      owner = owner()
      world(owner, %{name: "Saltmarch"})

      assert Library.name_taken?(owner, "world_bible", "Saltmarch")
      # How a person reads it, not how a database compares it.
      assert Library.name_taken?(owner, "world_bible", "  saltmarch ")
      refute Library.name_taken?(owner, "world_bible", "Low Water")
    end

    test "scoped to the owner and the kind" do
      mine = owner()
      theirs = owner()
      world(theirs, %{name: "Saltmarch"})

      refute Library.name_taken?(mine, "world_bible", "Saltmarch")

      Library.put(%{owner: mine, kind: "character", payload: %CharacterSheet{name: "Saltmarch"}})
      refute Library.name_taken?(mine, "world_bible", "Saltmarch")
    end

    test "saving a world under its own name is not a clash" do
      owner = owner()
      entry = world(owner, %{name: "Saltmarch"})

      assert Library.name_taken?(owner, "world_bible", "Saltmarch")
      refute Library.name_taken?(owner, "world_bible", "Saltmarch", except: entry.id)
    end

    test "a blank name is never taken — that's the empty-field case, not a clash" do
      owner = owner()
      world(owner, %{name: "Saltmarch"})

      refute Library.name_taken?(owner, "world_bible", "")
      refute Library.name_taken?(owner, "world_bible", "   ")
    end
  end
end
