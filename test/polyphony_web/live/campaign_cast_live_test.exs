defmodule PolyphonyWeb.CampaignCastLiveTest do
  @moduledoc "Managing a campaign's cast from the campaign overview (add/remove, world-scoped)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  setup :register_and_log_in_user

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  defp campaign(user, attrs) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  test "a blank campaign can be named from its settings", %{conn: conn, user: user} do
    camp = campaign(user, %{name: ""})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")
    assert html =~ "Untitled campaign"

    view |> form("#campaign-details", %{name: "The Long Con"}) |> render_change()

    assert Library.payload(Library.get(camp.id))[:name] == "The Long Con"

    # The premise is its own tab, and saving it must not blank the name. The screen
    # used to be one form, so every field was written on every change; with the tabs
    # each form carries only its own, and a key that isn't submitted is left alone.
    {:ok, premise_view, _} = live(conn, ~p"/campaigns/#{camp.id}?tab=premise")
    premise_view |> form("#campaign-premise", %{premise: "a heist"}) |> render_change()

    payload = Library.payload(Library.get(camp.id))
    assert payload[:premise] == "a heist"
    assert payload[:name] == "The Long Con"
  end

  test "a character is added to and removed from the cast by id, not name",
       %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    camp = campaign(user, %{})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
    assert html =~ "Nobody is in this story yet."

    view |> form("form[phx-submit=add_character]", %{id: to_string(mira.id)}) |> render_submit()

    # Stored as the stable id, not the name.
    assert Library.payload(Library.get(camp.id))[:character_ids] == [mira.id]
    assert render(view) =~ "Mira"

    view
    |> element("button[phx-click=remove_character][phx-value-id='#{mira.id}']")
    |> render_click()

    assert Library.payload(Library.get(camp.id))[:character_ids] == []
  end

  test "a renamed character stays in the cast (referenced by id)", %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    camp = campaign(user, %{character_ids: [mira.id]})

    # Rename the character after casting.
    Library.update_payload(mira.id, %CharacterSheet{name: "Mirabel", status: :full})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
    # Still cast, now shown under the new name.
    assert html =~ "Mirabel"
  end

  test "the add picker is scoped to the campaign's world (plus unassigned)",
       %{conn: conn, user: user} do
    bay =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    dune =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Red Dune"}
      })

    bay_char =
      character(user, %CharacterSheet{name: "BayNative", world_bible_id: bay.id, status: :full})

    dune_char =
      character(user, %CharacterSheet{name: "DuneNomad", world_bible_id: dune.id, status: :full})

    free = character(user, %CharacterSheet{name: "FreeAgent", status: :full})

    camp = campaign(user, %{bible_id: bay.id})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

    # Bay's own character and the unassigned one are offered (by id); the other world's isn't.
    assert html =~ ~s(<option value="#{bay_char.id}")
    assert html =~ ~s(<option value="#{free.id}")
    refute html =~ ~s(<option value="#{dune_char.id}")
  end

  test "the cast keeps the campaign's own order, not the library's",
       %{conn: conn, user: user} do
    # Voice colours are assigned by cast order and must be stable — the same
    # character is the same hue here, in the transcript and in the status strip. If
    # this read from the library query instead, creating an unrelated character
    # could reshuffle everyone's colour.
    a = character(user, %CharacterSheet{name: "Zeno", status: :full})
    b = character(user, %CharacterSheet{name: "Alma", status: :full})
    camp = campaign(user, %{character_ids: [a.id, b.id]})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

    assert :binary.match(html, "Zeno") < :binary.match(html, "Alma")
  end
end
