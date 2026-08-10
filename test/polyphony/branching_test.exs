defmodule Polyphony.BranchingTest do
  @moduledoc """
  Branches as an author-facing thing (STR-8): the campaign-level tree over
  `Fork.fork/3`'s scene streams.

  These tests go through `register_fork/5` — the half every caller shares — so
  they exercise the tree, naming, canonical, archive/delete/tombstones and the
  divergence cursor without standing up the event store. `Fork.fork/3` itself is
  pinned by `Polyphony.ForkTest`; `branch_from/4` is that plus this.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Branching, Library, Owner, Repo}
  alias Polyphony.ReadModels.BranchTombstone

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp campaign(scenes) do
    Library.put(%{
      owner: owner(),
      kind: "campaign",
      payload: %{kind: :campaign, name: "The Salt Line", character_ids: [], scenes: scenes}
    })
  end

  defp scenes_of(campaign_id),
    do: campaign_id |> Library.get() |> Library.payload() |> Map.get(:scenes)

  test "a campaign that has never branched carries no bookkeeping at all" do
    entry = campaign(["s1"])
    refute Branching.branched?(entry.id)
    assert Branching.tree(entry.id) == []
    assert Branching.line_of(entry.id, "s1") == nil
    # The whole scenes list is the (implicit) root line's.
    assert Branching.scenes_for(entry.id, nil) == ["s1"]
  end

  test "the first branch creates the root lazily — canonical, named for the campaign" do
    entry = campaign(["s1", "s2"])
    b = Branching.register_fork(entry.id, "s1", "s1-b", 3, location: "The quay")

    assert [%{branch: root, depth: 0}, %{branch: ^b, depth: 1}] = Branching.tree(entry.id)
    assert root.canonical
    assert root.name == "The Salt Line"
    assert root.parent_id == nil
    assert b.parent_id == root.id
    assert b.cut_beat == 3
    assert b.origin_scene_id == "s1"
    refute b.canonical
  end

  test "names default to scene · location · beat, ordinal only on collision" do
    entry = campaign(["s1"])
    a = Branching.register_fork(entry.id, "s1", "s1-a", 3, location: "The quay")
    b = Branching.register_fork(entry.id, "s1", "s1-b", 3, location: "The quay")
    c = Branching.register_fork(entry.id, "s1", "s1-c", 6, location: "The quay")

    assert a.name == "The quay · beat 3"
    assert b.name == "The quay · beat 3 (2)"
    # A different beat is not a collision — the common case stays clean.
    assert c.name == "The quay · beat 6"
  end

  test "the branch adopts its scene into the campaign, and scoping splits the lists" do
    entry = campaign(["s1", "s2"])
    b = Branching.register_fork(entry.id, "s1", "s1-b", 3, location: "The quay")

    # The campaign names the new stream — both lines stay playable.
    assert scenes_of(entry.id) == ["s1", "s2", "s1-b"]

    # The hub shows one line at a time: the root gets what nobody claimed.
    root = Branching.line_of(entry.id, "s1")
    assert root.parent_id == nil
    assert Branching.scenes_for(entry.id, root) == ["s1", "s2"]
    assert Branching.scenes_for(entry.id, b) == ["s1-b"]
    assert Branching.line_of(entry.id, "s1-b").id == b.id

    # A scene opened while working in the branch joins its line.
    Library.update_payload(entry.id, %{
      kind: :campaign,
      name: "The Salt Line",
      character_ids: [],
      scenes: ["s1", "s2", "s1-b", "s3"]
    })

    :ok = Branching.claim_scene(b.id, "s3")
    assert Branching.scenes_for(entry.id, Branching.line_of(entry.id, "s3")) == ["s1-b", "s3"]
    assert Branching.scenes_for(entry.id, root) == ["s1", "s2"]
  end

  test "canonical is one per campaign, and moves as a pair" do
    entry = campaign(["s1"])
    b = Branching.register_fork(entry.id, "s1", "s1-b", 2, location: "The quay")

    :ok = Branching.set_canonical(b.id)

    canon = Enum.filter(Branching.tree(entry.id), & &1.branch.canonical)
    assert [%{branch: %{id: id}}] = canon
    assert id == b.id
  end

  test "canonical can be neither archived nor deleted — set another line first" do
    entry = campaign(["s1"])
    b = Branching.register_fork(entry.id, "s1", "s1-b", 2, location: "The quay")
    :ok = Branching.set_canonical(b.id)

    assert {:error, :canonical} = Branching.archive(b.id)
    assert {:error, :canonical} = Branching.delete(b.id)
  end

  test "archiving hides a line from the default tree and is reversible" do
    entry = campaign(["s1"])
    b = Branching.register_fork(entry.id, "s1", "s1-b", 2, location: "The quay")

    :ok = Branching.archive(b.id)
    refute Enum.any?(Branching.tree(entry.id), &(&1.branch.id == b.id))
    assert Enum.any?(Branching.tree(entry.id, include_archived: true), &(&1.branch.id == b.id))

    :ok = Branching.unarchive(b.id)
    assert Enum.any?(Branching.tree(entry.id), &(&1.branch.id == b.id))
  end

  test "delete re-parents children to the grandparent and leaves a tombstone" do
    entry = campaign(["s1"])
    mid = Branching.register_fork(entry.id, "s1", "s1-mid", 3, location: "The quay")
    kid = Branching.register_fork(entry.id, "s1-mid", "s1-kid", 5, location: "The counting house")
    root = Enum.find(Branching.tree(entry.id), &(&1.depth == 0)).branch

    assert {:ok, %{deleted: 1, reparented: 1}} = Branching.delete(mid.id)

    # The child moved up under the grandparent and kept everything it copied.
    tree = Branching.tree(entry.id)
    assert %{depth: 1} = Enum.find(tree, &(&1.branch.id == kid.id))
    assert Enum.find(tree, &(&1.branch.id == kid.id)).branch.parent_id == root.id
    refute Enum.any?(tree, &(&1.branch.id == mid.id))

    # The line's scenes left the campaign; the record survives.
    assert scenes_of(entry.id) == ["s1", "s1-kid"]
    assert %BranchTombstone{parent_id: parent, cut_beat: 3} = BranchTombstone.get(Repo, mid.id)
    assert parent == root.id
  end

  test "recursive delete takes the subtree, each line leaving its own tombstone" do
    entry = campaign(["s1"])
    mid = Branching.register_fork(entry.id, "s1", "s1-mid", 3, location: "The quay")
    kid = Branching.register_fork(entry.id, "s1-mid", "s1-kid", 5, location: "The counting house")

    assert {:ok, %{deleted: 2, reparented: 0}} = Branching.delete(mid.id, recursive: true)

    assert [%{depth: 0}] = Branching.tree(entry.id)
    assert BranchTombstone.get(Repo, mid.id)
    assert BranchTombstone.get(Repo, kid.id)
    assert scenes_of(entry.id) == ["s1"]
  end

  test "a link into a deleted line resolves to the nearest surviving ancestor at the cut" do
    entry = campaign(["s1"])
    mid = Branching.register_fork(entry.id, "s1", "s1-mid", 3, location: "The quay")
    kid = Branching.register_fork(entry.id, "s1-mid", "s1-kid", 5, location: "The counting house")
    root = Enum.find(Branching.tree(entry.id), &(&1.depth == 0)).branch

    assert {:ok, %{id: id}} = Branching.resolve(kid.id)
    assert id == kid.id

    # Delete the subtree: a link to the kid walks up past the mid's own tombstone
    # and lands on the root — at the *kid's* cut, the last content the link
    # promised that still exists.
    {:ok, _} = Branching.delete(mid.id, recursive: true)
    assert {:moved, %{id: root_id}, 5} = Branching.resolve(kid.id)
    assert root_id == root.id

    assert :error = Branching.resolve(-1)
  end

  test "the cursor starts at the cut and only ever moves earlier" do
    entry = campaign(["s1"])
    b = Branching.register_fork(entry.id, "s1", "s1-b", 4, location: "The quay")

    assert Branching.cursor(b) == {"s1-b", 4}

    # A later change doesn't move it.
    :ok = Branching.notice_change(entry.id, "s1-b", 9)
    assert Branching.cursor(reload(b)) == {"s1-b", 4}

    # An earlier one does.
    :ok = Branching.notice_change(entry.id, "s1-b", 2)
    assert Branching.cursor(reload(b)) == {"s1-b", 2}
  end

  test "the cursor moves across scenes by the line's own order" do
    entry = campaign(["s1", "s2"])
    # Branch, then grow the line to two scenes.
    b = Branching.register_fork(entry.id, "s1", "b-first", 3, location: "The quay")

    Library.update_payload(entry.id, %{
      kind: :campaign,
      name: "The Salt Line",
      character_ids: [],
      scenes: ["s1", "s2", "b-first", "b-second"]
    })

    :ok = Branching.claim_scene(b.id, "b-second")

    # A change in the later scene, at a *lower* beat, is still later than the
    # cursor sitting in the earlier scene.
    :ok = Branching.notice_change(entry.id, "b-second", 1)
    assert Branching.cursor(reload(b)) == {"b-first", 3}

    # Deleting content back in the first scene pulls it earlier.
    :ok = Branching.notice_change(entry.id, "b-first", 0)
    assert Branching.cursor(reload(b)) == {"b-first", 0}
  end

  defp reload(branch), do: Polyphony.ReadModels.Branch.get(Repo, branch.id)
end
