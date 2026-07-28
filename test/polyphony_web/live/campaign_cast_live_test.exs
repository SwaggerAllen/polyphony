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

  test "a character can be added to and removed from the cast", %{conn: conn, user: user} do
    character(user, %CharacterSheet{name: "Mira", status: :full})
    camp = campaign(user, %{})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}")
    assert html =~ "No cast yet"

    view |> form("form[phx-submit=add_character]", %{name: "Mira"}) |> render_submit()

    assert Library.payload(Library.get(camp.id))[:character_ids] == ["Mira"]
    assert render(view) =~ "Mira"

    view
    |> element("button[phx-click=remove_character][phx-value-name=Mira]")
    |> render_click()

    assert Library.payload(Library.get(camp.id))[:character_ids] == []
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

    character(user, %CharacterSheet{name: "BayNative", world_bible_id: bay.id, status: :full})
    character(user, %CharacterSheet{name: "DuneNomad", world_bible_id: dune.id, status: :full})
    character(user, %CharacterSheet{name: "FreeAgent", status: :full})

    camp = campaign(user, %{bible_id: bay.id})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}")

    # Bay's own character and the unassigned one are offered; the other world's isn't.
    assert html =~ ~s(<option value="BayNative")
    assert html =~ ~s(<option value="FreeAgent")
    refute html =~ ~s(<option value="DuneNomad")
  end

  test "adding a character not offered without a world still works once world is cleared",
       %{conn: conn, user: user} do
    dune =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Red Dune"}
      })

    character(user, %CharacterSheet{name: "DuneNomad", world_bible_id: dune.id, status: :full})
    camp = campaign(user, %{})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}")
    # With no world attached, every owned character is offered.
    assert html =~ ~s(<option value="DuneNomad")
  end
end
