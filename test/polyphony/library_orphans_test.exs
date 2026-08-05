defmodule Polyphony.LibraryOrphansTest do
  @moduledoc """
  Characters no story has on its roster, and the two ways cleaning them up could destroy
  something instead.

  Three paths used to invent people and attach them to nothing: a stub written from a
  relationship, a name mentioned mid-scene, and Quick Build's off-screen walk-ons. All
  three now call `Campaigns.cast/3`, so this is about the ones that already exist —
  and about making the sweep that removes them safe enough to run against real data.

  The two errors are not symmetrical, which is the whole design of the read. Leaving an
  orphan behind costs a row in a list. Deleting somebody a story needs costs the story.
  So the roster scan is as wide as possible — archived, trashed and hidden campaigns
  count, and so do the characters a published snapshot pinned — and anything it cannot
  read raises rather than being counted as an empty roster.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.CharacterSheet

  setup do
    %{user: user_fixture()}
  end

  defp character(user, name, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name, status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp campaign(user, ids) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "campaign",
      payload: %{kind: :campaign, name: "Camp", character_ids: ids, bible_id: nil, scenes: []}
    })
  end

  defp orphan_ids, do: Library.orphaned_characters() |> Enum.map(& &1.id) |> Enum.sort()

  describe "who counts as an orphan" do
    test "a character on a roster does not", %{user: user} do
      wren = character(user, "Wren")
      campaign(user, [wren.id])

      refute wren.id in orphan_ids()
    end

    test "a character on nobody's roster does", %{user: user} do
      wren = character(user, "Wren")
      loose = character(user, "The bellman", %{status: :stub})
      campaign(user, [wren.id])

      assert orphan_ids() == [loose.id]
    end

    test "an archived character does not — filing something is keeping it", %{user: user} do
      loose = character(user, "The bellman", %{status: :stub})
      Library.archive(loose.id)

      refute loose.id in orphan_ids()
    end

    test "one already in the trash is not swept twice", %{user: user} do
      loose = character(user, "The bellman", %{status: :stub})
      Library.soft_delete(loose.id)

      refute loose.id in orphan_ids()
    end
  end

  describe "what still protects a character" do
    test "an archived campaign", %{user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, [wren.id])
      Library.archive(camp.id)

      # Filed away is not gone. Restoring the campaign has to restore a cast.
      refute wren.id in orphan_ids()
    end

    test "a campaign in the trash", %{user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, [wren.id])
      Library.soft_delete(camp.id)

      # It is restorable for thirty days, and gutting its cast in the meantime would
      # make the restore a lie.
      refute wren.id in orphan_ids()
    end

    test "a published snapshot that pinned them", %{user: user} do
      wren = character(user, "Wren")

      # A snapshot outlives the campaign it froze — it holds pinned copies keyed by
      # `source_id`, and a reader can fork from it. Deleting the source of a published
      # story is not orphan cleanup.
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        frozen: true,
        payload: %Polyphony.Library.Snapshot{
          campaign_id: "gone",
          characters: [%{source_id: wren.id, source_version: 1, sheet: %{}}]
        }
      })

      refute wren.id in orphan_ids()
    end

    test "a roster stored as strings, which is how some were written", %{user: user} do
      wren = character(user, "Wren")
      campaign(user, [to_string(wren.id)])

      refute wren.id in orphan_ids()
    end
  end

  describe "a roster it can't read" do
    test "raises rather than counting as empty", %{user: user} do
      wren = character(user, "Wren")
      campaign(user, [wren.id])

      # Corrupt one campaign's payload. Treating "unknown" as "no characters" is exactly
      # how a cleanup deletes the cast of the one story it couldn't parse — so the sweep
      # must stop instead.
      Polyphony.Repo.query!(
        "UPDATE library_entries SET payload = $1 WHERE kind = 'campaign'",
        [<<0, 1, 2, 3>>]
      )

      assert_raise ArgumentError, fn -> Library.orphaned_characters() end
    end
  end

  describe "the sweep" do
    test "trashes orphans and leaves everyone else alone", %{user: user} do
      wren = character(user, "Wren")
      loose = character(user, "The bellman", %{status: :stub})
      campaign(user, [wren.id])

      assert [%{id: id}] = Library.trash_orphaned_characters()
      assert id == loose.id

      # Soft: on the trash shelf with the ordinary window, so anything this catches that
      # somebody wanted is one Restore away.
      assert Library.live?(Library.get(wren.id))
      refute Library.live?(Library.get(loose.id))
      assert Library.trash(Owner.of(user)) |> Enum.map(& &1.id) == [loose.id]

      {:ok, _} = Library.restore(loose.id)
      assert Library.live?(Library.get(loose.id))
    end

    test "is a no-op when there are none", %{user: user} do
      wren = character(user, "Wren")
      campaign(user, [wren.id])

      assert Library.trash_orphaned_characters() == []
    end
  end
end
