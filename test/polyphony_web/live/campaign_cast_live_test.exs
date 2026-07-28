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

  test "a blank campaign can be named from its overview", %{conn: conn, user: user} do
    camp = campaign(user, %{name: ""})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}")
    assert html =~ "Untitled campaign"

    view
    |> form("form[phx-change=update_details]", %{name: "The Long Con", premise: "a heist"})
    |> render_change()

    payload = Library.payload(Library.get(camp.id))
    assert payload[:name] == "The Long Con"
    assert payload[:premise] == "a heist"
  end

  test "a character is added to and removed from the cast by id, not name",
       %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    camp = campaign(user, %{})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}")
    assert html =~ "No cast yet"

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

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}")
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

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}")

    # Bay's own character and the unassigned one are offered (by id); the other world's isn't.
    assert html =~ ~s(<option value="#{bay_char.id}")
    assert html =~ ~s(<option value="#{free.id}")
    refute html =~ ~s(<option value="#{dune_char.id}")
  end
end
