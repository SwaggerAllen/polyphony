defmodule Polyphony.ReadingLinesTest do
  @moduledoc """
  The reading side of branching (STR-8): a publication knows which line it is,
  carries the other lines unlisted, and answers *which line is this scene in*,
  *where do two lines last agree*, and *has this reader already chosen to stay* —
  all from the frozen snapshot, never the author's live campaign.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Owner, Reading, Repo}
  alias Polyphony.Library.Snapshot
  alias Polyphony.Reading.Session

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp scene(id, title), do: %{id: id, title: title, cast: ["wren"], beats: 3}

  # Canonical is a branch cut in s2: it shares s1 with the old root line, then
  # goes its own way. The root line travels unlisted.
  defp snapshot do
    Snapshot.build(%{
      campaign_id: "camp-1",
      scenes: [scene("s1", "The tide bell"), scene("b1", "The quay, again")],
      branch_id: 7,
      lines: [
        %{
          id: 3,
          name: "The Salt Line",
          parent_id: nil,
          cut_beat: nil,
          scenes: [scene("s1", "The tide bell"), scene("s2", "What the ledger says")],
          names: %{"wren" => "Wren Ashgrove"},
          heads: %{}
        }
      ],
      publication: %{spectator: true, perspectives: [], forkable: false}
    })
  end

  test "which line a scene is in, from the snapshot alone" do
    snap = snapshot()

    assert Session.line_for_scene(snap, "b1") == :canonical
    assert Session.line_for_scene(snap, "s1") == :canonical
    assert %{id: 3} = Session.line_for_scene(snap, "s2")
    assert Session.line_for_scene(snap, "gone") == nil
  end

  test "the last point two lines share is the deepest scene their lists agree on" do
    snap = snapshot()
    line = Session.line_for_scene(snap, "s2")

    assert %{id: "s1"} = Session.shared_point(snap, line)
  end

  test "lines that share nothing that survived share no point" do
    snap = snapshot()
    stranger = %{id: 9, scenes: [scene("x1", "Elsewhere")]}

    assert Session.shared_point(snap, stranger) == nil
  end

  test "staying on a line is remembered on the bookmark, once per line" do
    reader = Owner.coerce(System.unique_integer([:positive]))

    published =
      Library.put(%{owner: reader, kind: "campaign", frozen: true, payload: snapshot()})

    Reading.mark(reader, published.id, %{scene_id: "s2", perspective: "omniscient"})
    assert Reading.bookmark(reader, published.id).stayed_line_id == nil

    :ok = Reading.stay(reader, published.id, 3)
    assert Reading.bookmark(reader, published.id).stayed_line_id == "3"

    # Moving the place keeps the answer — the question was about the line, not
    # the scene.
    Reading.mark(reader, published.id, %{scene_id: "s1", perspective: "omniscient"})
    assert Reading.bookmark(reader, published.id).stayed_line_id == "3"
  end
end
