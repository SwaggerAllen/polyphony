defmodule PolyphonyWeb.CampaignPublishLiveTest do
  @moduledoc """
  Publishing, driven through the screen rather than through `Library.publish_campaign/2`.

  This file exists because of what its absence hid. Every publishing test called the
  domain function directly with the arguments it wanted, so nothing ever exercised the
  button — which had been passing `:owner` to a function demanding `:owner_id` and
  raising. And because nothing ever *successfully* published, nothing ever had a
  snapshot sitting in a library, which is what took the library screen down the moment
  a real author did.

  The lesson is the shape of the test, not the bug: a path whose only coverage calls
  past the UI is a path with no coverage of the UI.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Campaigns, Library, Owner, Reading}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Library.Snapshot

  setup :register_and_log_in_user

  defp campaign(user, attrs \\ %{}) do
    bible =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Saltmarch"}
      })

    wren =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full}
      })

    payload =
      Map.merge(
        %{
          kind: :campaign,
          name: "The Salt Line",
          bible_id: bible.id,
          character_ids: [wren.id],
          scenes: []
        },
        attrs
      )

    {Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload}), wren}
  end

  test "the Publish button actually publishes", %{conn: conn, user: user} do
    {entry, _wren} = campaign(user)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{entry.id}?tab=cast")
    html = view |> element("button[phx-click=publish]") |> render_click()

    assert html =~ "Published. Anyone with the link reads this."

    assert [snapshot] = Library.publications_of(entry)
    assert %Snapshot{} = Library.payload(snapshot)
    assert snapshot.frozen
    assert snapshot.visibility == "public"
    # And it knows what it froze.
    assert snapshot.derived_from_id == entry.id
  end

  test "the grant the author ticked is what travels with it", %{conn: conn, user: user} do
    {entry, wren} = campaign(user)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{entry.id}?tab=cast")
    view |> element("[phx-click=toggle_perspective][phx-value-id='#{wren.id}']") |> render_click()
    view |> element("[phx-click=toggle_forkable]") |> render_click()
    view |> element("button[phx-click=publish]") |> render_click()

    [snapshot] = Library.publications_of(entry)
    pub = Library.payload(snapshot).publication

    assert pub.perspectives == [to_string(wren.id)]
    assert pub.forkable
  end

  test "and the library survives it — the campaign stays, the snapshot doesn't appear",
       %{conn: conn, user: user} do
    {entry, _wren} = campaign(user, %{scenes: ["s1"]})

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{entry.id}?tab=cast")
    view |> element("button[phx-click=publish]") |> render_click()

    {:ok, _view, html} = live(conn, ~p"/library")

    # One row, the live campaign, wearing the badge — not two, and not a crash.
    assert html =~ "The Salt Line"
    assert html =~ "Published"
    refute html =~ "Untitled campaign"
    assert [%{id: id}] = Campaigns.list(Owner.of(user))
    assert id == entry.id
  end

  describe "republishing" do
    test "replaces the published copy in place, keeping its id", %{conn: conn, user: user} do
      {entry, _wren} = campaign(user)

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{entry.id}?tab=cast")
      view |> element("button[phx-click=publish]") |> render_click()
      [first] = Library.publications_of(entry)

      {:ok, view, html} = live(conn, ~p"/campaigns/#{entry.id}?tab=cast")
      # The button says which of the two things it is.
      assert html =~ "Update what&#39;s published"
      view |> element("button[phx-click=publish]") |> render_click()

      # One copy, same id — so every link, bookmark and share URL still resolves.
      assert [second] = Library.publications_of(entry)
      assert second.id == first.id
      assert second.version > first.version
    end

    test "and a reader partway through gets the continuation", %{user: author} do
      reader = user_fixture()
      {entry, _wren} = campaign(author)

      Library.publish_campaign(
        %{
          owner: Owner.of(author),
          campaign_id: entry.id,
          bible: %WorldBible{name: "Saltmarch"},
          characters: [],
          arc: [],
          scenes: [%{id: "s1", title: "The quay", cast: [], beats: 3}]
        },
        visibility: "public"
      )

      published = Library.publication_of(entry)
      Reading.mark(Owner.of(reader), published.id, %{scene_id: "s1", perspective: "spectator"})

      # The author plays on and publishes again.
      Library.publish_campaign(
        %{
          owner: Owner.of(author),
          campaign_id: entry.id,
          bible: %WorldBible{name: "Saltmarch"},
          characters: [],
          arc: [],
          scenes: [
            %{id: "s1", title: "The quay", cast: [], beats: 3},
            %{id: "s2", title: "The counting house", cast: [], beats: 5}
          ]
        },
        visibility: "public"
      )

      [row] = Reading.shelf(Owner.of(reader))

      # Their place is re-found by scene id — stable, it's the stream id — so the
      # story simply got longer rather than the bookmark going stale.
      assert row.bookmark.published_id == published.id
      assert Reading.position(row.bookmark, row.source) == {1, 2}
      assert row.state == :reading
    end

    test "and the shelf says so when their scene didn't survive the update", %{
      conn: conn,
      user: reader
    } do
      author = user_fixture()

      entry =
        Library.put(%{
          owner: Owner.of(author),
          kind: "campaign",
          payload: %{kind: :campaign, name: "The Salt Line", character_ids: [], scenes: []}
        })

      publish_with = fn scenes ->
        Library.publish_campaign(
          %{
            owner: Owner.of(author),
            campaign_id: entry.id,
            bible: %WorldBible{name: "Saltmarch"},
            characters: [],
            arc: [],
            scenes: scenes
          },
          visibility: "public"
        )
      end

      publish_with.([%{id: "cut", title: "A scene since removed", cast: [], beats: 2}])
      published = Library.publication_of(entry)
      Reading.mark(Owner.of(reader), published.id, %{scene_id: "cut"})

      publish_with.([%{id: "kept", title: "The quay", cast: [], beats: 3}])

      {:ok, _view, html} = live(conn, ~p"/library?tab=reading")

      # Honest about the cost rather than quietly starting them over.
      assert html =~ "isn&#39;t in this version any more"
    end

    test "browse shows one story, not the old one with the new as a fork", %{
      conn: conn,
      user: author
    } do
      {entry, _wren} = campaign(author)

      for _ <- 1..2 do
        Library.publish_campaign(
          %{
            owner: Owner.of(author),
            campaign_id: entry.id,
            bible: %WorldBible{name: "Saltmarch"},
            characters: [],
            arc: []
          },
          visibility: "public"
        )
      end

      {:ok, _view, html} = live(conn, ~p"/browse")

      assert Enum.count(Regex.scan(~r/Saltmarch/, html)) == 1
      refute html =~ "other version"
    end

    test "a taken-down story can't be republished back into existence", %{user: author} do
      _ = Polyphony.Accounts.Roles.roles()
      admin = user_fixture(%{role: "admin"})
      {entry, _wren} = campaign(author)

      published =
        Library.publish_campaign(
          %{
            owner: Owner.of(author),
            campaign_id: entry.id,
            bible: %WorldBible{name: "Saltmarch"},
            characters: [],
            arc: []
          },
          visibility: "public"
        )

      {:ok, report} =
        Polyphony.Moderation.file_report(user_fixture(), %{
          item_type: "library_entry",
          item_id: published.id,
          owner_id: author.id,
          reason: "harassment",
          detail: "x"
        })

      {:ok, _} = Polyphony.Moderation.take_down(admin, report, "upheld")

      # Publishing again is not an appeal.
      assert {:error, :hidden} =
               Library.publish_campaign(
                 %{
                   owner: Owner.of(author),
                   campaign_id: entry.id,
                   bible: %WorldBible{name: "Saltmarch"},
                   characters: [],
                   arc: []
                 },
                 visibility: "public"
               )

      assert Library.list_public("campaign") == []
    end
  end

  test "the published copy is readable, and the editor sends you there", %{conn: conn, user: user} do
    {entry, _wren} = campaign(user)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{entry.id}?tab=cast")
    view |> element("button[phx-click=publish]") |> render_click()
    [snapshot] = Library.publications_of(entry)

    # Opening the editor on a frozen copy is a category error with an obvious answer.
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/campaigns/#{snapshot.id}")
    assert to =~ "/browse?story=#{snapshot.id}"

    {:ok, _view, html} = live(conn, ~p"/browse")
    assert html =~ "Saltmarch"
  end
end
