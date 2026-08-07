defmodule Polyphony.LibraryFamilyTest do
  @moduledoc """
  Root identity on derived artifacts (§3.1d).

  Every campaign copies its world (§2.5b) and every fork copies everything, so within a
  year there are a dozen artifacts called Saltmarch. A parent pointer alone can't group
  that list — you'd walk the chain per row — and a flat list of near-identical names is
  what makes both Browse and the library unusable at that point.

  The property that matters is the one a parent pointer *doesn't* give you: **a fork of
  a fork still groups under the thing it all started from**, not under its immediate
  ancestor.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.WorldBible

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp person, do: Owner.coerce(System.unique_integer([:positive]))

  defp world(owner, name \\ "Saltmarch"),
    do: Library.put(%{owner: owner, kind: "world_bible", payload: %WorldBible{name: name}})

  test "an original is its own root, written down rather than left null" do
    entry = world(person())

    assert Library.root_of(Library.get(entry.id)) == entry.id
    assert Library.get(entry.id).root_id == entry.id
  end

  test "a copy carries the original's root" do
    owner = person()
    original = world(owner)
    copy = Library.copy(original, owner)

    assert copy.root_id == original.id
    assert copy.derived_from_id == original.id
  end

  test "a fork of a fork groups under the original, not its parent" do
    owner = person()
    original = world(owner)
    first = Library.copy(original, owner)
    second = Library.copy(first, owner)

    # The parent pointer still records the real ancestor…
    assert second.derived_from_id == first.id
    # …and the root still reaches all the way back. This is the whole entry.
    assert second.root_id == original.id
  end

  test "the family is the original and everything descended from it" do
    owner = person()
    original = world(owner)
    a = Library.copy(original, owner)
    b = Library.copy(a, owner)
    unrelated = world(owner, "Kettleworth")

    ids = original |> Library.family() |> Enum.map(& &1.id) |> Enum.sort()

    assert ids == Enum.sort([original.id, a.id, b.id])
    refute unrelated.id in ids
  end

  test "any member of a family reaches the same family" do
    owner = person()
    original = world(owner)
    copy = Library.copy(original, owner)

    from_root = original |> Library.family() |> Enum.map(& &1.id) |> Enum.sort()
    from_leaf = copy |> Library.family() |> Enum.map(& &1.id) |> Enum.sort()

    assert from_root == from_leaf
  end

  test "a family crosses owners — which is what Browse groups by" do
    author = person()
    reader = person()
    original = world(author)
    theirs = Library.copy(original, reader)

    ids = original |> Library.family() |> Enum.map(& &1.id)

    assert theirs.id in ids
  end

  test "provenance walks back to the parent and to the original" do
    owner = person()
    original = world(owner, "Kettleworth, Second Shift")
    first = Library.copy(original, owner)
    second = Library.copy(first, owner)

    {parent, root} = Library.provenance(Library.get(second.id))

    assert parent.id == first.id
    assert root.id == original.id

    # An original came from nowhere, and says so rather than pointing at itself.
    assert {nil, nil} = Library.provenance(Library.get(original.id))
  end

  test "a deleted copy leaves the family" do
    owner = person()
    original = world(owner)
    copy = Library.copy(original, owner)
    {:ok, _} = Library.soft_delete(copy.id)

    ids = original |> Library.family() |> Enum.map(& &1.id)

    refute copy.id in ids
    assert original.id in ids
  end
end
