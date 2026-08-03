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

  alias Polyphony.{Campaigns, Library, Owner}
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

    assert html =~ "Published a public snapshot"

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
