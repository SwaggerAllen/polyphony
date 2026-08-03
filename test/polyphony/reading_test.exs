defmodule Polyphony.ReadingTest do
  @moduledoc """
  The reading shelf (§3.1e) — the library's fourth tab, and the one thing it promises:
  *you can get back to where you were*.

  Two properties carry the design, and both are easy to get wrong in the same
  direction — by treating a story you're reading as a campaign you own:

    * **Perspective travels with the place.** Scene and beat alone put you back in the
      right paragraph in the wrong head, which is a different story.
    * **Unpublishing keeps the bookmark.** The row goes `:gone`, the place survives.
      Dropping it would be unrecoverable from the reader's side, and unpublishing is
      usually temporary.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Owner, Reading, Repo}
  alias Polyphony.Reading.Bookmark

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp person, do: Owner.coerce(System.unique_integer([:positive]))

  defp published(author, attrs \\ %{}) do
    payload =
      Map.merge(%{kind: :campaign, name: "The Ninth Gate", scenes: ["s1", "s2", "s3"]}, attrs)

    Library.put(%{owner: author, kind: "campaign", visibility: "public", payload: payload})
  end

  describe "keeping a place" do
    test "a bookmark is scene, beat and perspective together" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s2", beat: 4, perspective: "char-7"})

      assert {"s2", 4, "char-7"} = Reading.resume(reader, story.id)
    end

    test "a reader has one place per story, not a pile of them" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s1", beat: 1})
      Reading.mark(reader, story.id, %{scene_id: "s2", beat: 9})

      assert [row] = Reading.shelf(reader)
      assert row.bookmark.scene_id == "s2"
      assert row.bookmark.beat == 9
    end

    test "never opened means no bookmark rather than a zeroed one" do
      assert Reading.resume(person(), 1234) == nil
      assert Reading.bookmark(person(), 1234) == nil
    end

    test "going back in un-finishes it" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s3", beat: 2})
      {:ok, _} = Reading.finish(reader, story.id)
      assert [%{state: :finished}] = Reading.shelf(reader)

      Reading.mark(reader, story.id, %{scene_id: "s2", beat: 1})
      assert [%{state: :reading}] = Reading.shelf(reader)
    end

    test "forgetting takes it off the shelf, and only the reader can" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s1"})
      assert :ok = Reading.forget(reader, story.id)
      assert Reading.shelf(reader) == []
    end
  end

  describe "when the author pulls it" do
    test "the row stays, the place survives, and it reads as gone" do
      reader = person()
      author = person()
      story = published(author)

      Reading.mark(reader, story.id, %{scene_id: "s2", beat: 4, perspective: "char-7"})
      Library.set_visibility(story.id, "private")

      assert [row] = Reading.shelf(reader)
      assert row.state == :gone
      # The whole point: it may come back, and this is where they were.
      assert {"s2", 4, "char-7"} = Reading.resume(reader, story.id)
    end

    test "deleting it outright reads as gone too" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s1"})
      {:ok, _} = Library.soft_delete(story.id)

      assert [%{state: :gone}] = Reading.shelf(reader)
    end

    test "a finished story that's pulled is gone, not finished" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s3"})
      {:ok, _} = Reading.finish(reader, story.id)
      Library.set_visibility(story.id, "private")

      assert [%{state: :gone}] = Reading.shelf(reader)
    end

    test "an unlisted story is still readable — a share link is a grant" do
      reader = person()
      story = published(person())

      Reading.mark(reader, story.id, %{scene_id: "s1"})
      Library.set_visibility(story.id, "unlisted")

      assert [%{state: :reading}] = Reading.shelf(reader)
    end
  end

  describe "how a row reads" do
    test "position is one-based and comes from the published entry" do
      reader = person()
      story = published(person())
      Reading.mark(reader, story.id, %{scene_id: "s2"})

      [row] = Reading.shelf(reader)
      assert Reading.position(row.bookmark, row.source) == {2, 3}
    end

    test "a scene the published entry doesn't list has no position rather than a wrong one" do
      reader = person()
      story = published(person())
      Reading.mark(reader, story.id, %{scene_id: "s9"})

      [row] = Reading.shelf(reader)
      assert Reading.position(row.bookmark, row.source) == nil
    end

    test "a gone story has no position, because there's nothing left to ask" do
      assert Reading.position(%Bookmark{scene_id: "s1"}, nil) == nil
    end

    test "perspective reads as a name, resolved at the edge" do
      assert Reading.perspective_label(%Bookmark{perspective: "c1"}, %{"c1" => "Halden"}) ==
               "As Halden"

      # Identity fallback, same as `Scene.Cast` — an unmapped id passes through.
      assert Reading.perspective_label(%Bookmark{perspective: "c9"}, %{}) == "As c9"
      assert Reading.perspective_label(%Bookmark{perspective: :omniscient}) == "Everything"
    end
  end

  describe "the shelf's order" do
    test "most recently read first — where you'd look for it" do
      reader = person()
      old = published(person(), %{name: "Old"})
      new = published(person(), %{name: "New"})

      long_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -30 * 86_400, :second)
      Reading.mark(reader, old.id, %{scene_id: "s1"}, now: long_ago)
      Reading.mark(reader, new.id, %{scene_id: "s1"})

      assert [first, second] = Reading.shelf(reader)
      assert first.bookmark.published_id == new.id
      assert second.bookmark.published_id == old.id
    end

    test "one reader's shelf is not another's" do
      a = person()
      b = person()
      story = published(person())

      Reading.mark(a, story.id, %{scene_id: "s1"})

      assert length(Reading.shelf(a)) == 1
      assert Reading.shelf(b) == []
    end
  end
end
