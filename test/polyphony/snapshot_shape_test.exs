defmodule Polyphony.SnapshotShapeTest do
  @moduledoc """
  A published snapshot is **not** a campaign.

  They share the `"campaign"` kind because they share a table, and nothing else: a
  snapshot can't be played, finished, cast or reviewed, and its payload is a
  `Library.Snapshot` — a struct, with none of a campaign's fields and no `Access`, so
  `payload[:scenes]` on one *raises* rather than returning nil.

  That combination is why this file exists. Anything that said "a campaign is an entry
  of kind campaign" quietly worked until somebody published, and then took the screen
  down. These tests pin the distinction at the door rather than at each call site,
  because the failure mode is a crash in a list you can't get past.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Campaigns, Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Library.Snapshot

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp campaign(owner, attrs \\ %{}) do
    payload =
      Map.merge(%{kind: :campaign, name: "The Salt Line", character_ids: [], scenes: []}, attrs)

    Library.put(%{owner: owner, kind: "campaign", payload: payload})
  end

  defp publish(owner, campaign) do
    Library.publish_campaign(
      %{
        owner: owner,
        campaign_id: campaign.id,
        bible: %WorldBible{name: "Saltmarch"},
        characters: [],
        arc: []
      },
      visibility: "public"
    )
  end

  describe "the distinction" do
    test "a snapshot is one, a campaign isn't" do
      owner = owner()
      entry = campaign(owner)
      snapshot = publish(owner, entry)

      assert Library.snapshot?(snapshot)
      refute Library.snapshot?(Library.get(entry.id))

      assert Campaigns.campaign?(Library.get(entry.id))
      refute Campaigns.campaign?(snapshot)
    end

    test "the payload really is a struct with no Access — the reason for all of this" do
      owner = owner()
      snapshot = publish(owner, campaign(owner))
      payload = Library.payload(snapshot)

      assert %Snapshot{} = payload

      assert_raise UndefinedFunctionError, fn ->
        # What `payload[:scenes]` compiles to. It is not a nil-returning read.
        Access.get(payload, :scenes)
      end
    end
  end

  describe "what publishing leaves behind" do
    test "the campaign stays live and playable — publishing freezes a copy" do
      owner = owner()
      entry = campaign(owner, %{scenes: ["s1"]})
      publish(owner, entry)

      live = Library.get(entry.id)
      refute live.frozen
      assert Campaigns.status(Library.payload(live)) == :playing
      assert Enum.any?(Campaigns.list(owner), &(&1.id == entry.id))
    end

    test "and the snapshot is not in the campaign list" do
      owner = owner()
      snapshot = publish(owner, campaign(owner))

      refute Enum.any?(Campaigns.list(owner), &(&1.id == snapshot.id))
    end

    test "the snapshot records which campaign it froze" do
      owner = owner()
      entry = campaign(owner)
      snapshot = publish(owner, entry)

      assert snapshot.derived_from_id == entry.id
      # So "has this been published?" is an indexed read, not a payload scan.
      assert Library.published?(entry)
      assert [%{id: id}] = Library.publications_of(entry)
      assert id == snapshot.id
    end

    test "a campaign nobody published says so" do
      owner = owner()
      refute Library.published?(campaign(owner))
    end

    test "there is one published copy, and republishing replaces it" do
      owner = owner()
      entry = campaign(owner)
      first = publish(owner, entry)
      second = publish(owner, entry)

      # Same row, bumped — so every link, bookmark and share URL still resolves, and
      # no copy accumulates that nobody will read again.
      assert second.id == first.id
      assert second.version > first.version
      assert [%{id: id}] = Library.publications_of(entry)
      assert id == first.id
      assert Library.publication_of(entry).id == first.id
    end

    test "the published copy still descends from the campaign it froze" do
      owner = owner()
      entry = campaign(owner)
      published = publish(owner, entry)

      assert published.derived_from_id == entry.id
      assert published.root_id == entry.id
    end
  end

  describe "what a snapshot must never be treated as" do
    test "scene reset leaves a published snapshot's scenes alone" do
      owner = owner()
      entry = campaign(owner, %{scenes: ["s1", "s2"]})

      snapshot =
        Library.publish_campaign(
          %{
            owner: owner,
            campaign_id: entry.id,
            bible: %WorldBible{name: "Saltmarch"},
            characters: [],
            arc: [],
            scenes: [%{id: "s1", title: "The quay", cast: [], beats: 3}]
          },
          visibility: "public"
        )

      # `streams: false` — the test env uses the in-memory event store.
      Polyphony.SceneReset.run!(streams: false)

      # The live campaign's links are gone with the streams…
      assert Library.payload(Library.get(entry.id)).scenes == []
      # …and the frozen record of what was published is untouched. Blanking it would
      # empty the contents list and the reading position of every reader who has one.
      assert [%{id: "s1"}] = Library.payload(Library.get(snapshot.id)).scenes
    end

    test "browse won't open a live campaign as if it were a story" do
      owner = owner()
      entry = campaign(owner)
      {:ok, _} = Library.set_visibility(entry.id, "public")

      refute Library.snapshot?(Library.get(entry.id))
    end
  end

  describe "the reads that used to raise" do
    test "every campaign lifecycle read survives being handed a snapshot" do
      owner = owner()
      snapshot = publish(owner, campaign(owner))
      payload = Library.payload(snapshot)

      # Defence in depth: `list/2` keeps them out, but a lifecycle read is exactly the
      # kind of thing that gets called from somewhere new.
      assert Campaigns.status(payload) == :unstarted
      assert Campaigns.pending_review(snapshot) == 0
      assert is_map(Campaigns.by_character(owner))
    end

    test "a snapshot is named by its world, not rendered untitled" do
      owner = owner()
      snapshot = publish(owner, campaign(owner))

      assert Campaigns.name(snapshot) == "Saltmarch"
    end

    test "grouping people by campaign ignores snapshots" do
      owner = owner()

      wren =
        Library.put(%{owner: owner, kind: "character", payload: %CharacterSheet{name: "Wren"}})

      entry = campaign(owner, %{character_ids: [wren.id]})
      publish(owner, entry)

      by = Campaigns.by_character(owner)

      assert by[to_string(wren.id)].id == entry.id
    end
  end
end
