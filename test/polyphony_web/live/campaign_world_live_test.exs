defmodule PolyphonyWeb.CampaignWorldLiveTest do
  @moduledoc "Associating a world bible with a campaign from the campaign view."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible

  setup :register_and_log_in_user

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  test "the world selector lists the author's bibles and persists a choice", %{
    conn: conn,
    user: user
  } do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    camp = campaign(user)

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
    assert html =~ "Neon Bay"
    # Nothing attached: the selector sits on "— none —" and there is no edit link.
    assert html =~ ~r{<option value=""[^>]*>— none —}
    refute html =~ "Edit world"

    view
    |> form("form[phx-change=select_world]", %{bible_id: to_string(wb.id)})
    |> render_change()

    # **Attaching copies** (§2.5b). The campaign holds its own bible, not the library
    # one, because a campaign accumulates world arc and two campaigns cannot write
    # different histories onto one bible. The template stays a template.
    attached = Library.payload(Library.get(camp.id))[:bible_id]
    refute attached == wb.id

    copy = Library.get(attached)
    assert copy.derived_from_id == wb.id
    assert Library.payload(copy).name == "Neon Bay"
    assert Library.copy_count(wb.id) == 1
  end

  test "editing the library world does not reach a campaign already started from it",
       %{conn: conn, user: user} do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay", tone: "Wet neon"}
      })

    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

    view
    |> form("form[phx-change=select_world]", %{bible_id: to_string(wb.id)})
    |> render_change()

    attached = Library.payload(Library.get(camp.id))[:bible_id]
    {:ok, _} = Library.update_payload(wb.id, %WorldBible{name: "Neon Bay", tone: "Dry heat"})

    # The honest limitation the design states rather than implies away.
    assert Library.payload(Library.get(attached)).tone == "Wet neon"
  end

  test "re-selecting the campaign's own copy does not copy the copy",
       %{conn: conn, user: user} do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    camp = campaign(user, %{bible_id: wb.id})
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

    view
    |> form("form[phx-change=select_world]", %{bible_id: to_string(wb.id)})
    |> render_change()

    assert Library.payload(Library.get(camp.id))[:bible_id] == wb.id
    assert Library.copy_count(wb.id) == 0
  end

  test "a linked world is shown and can be cleared", %{conn: conn, user: user} do
    wb =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    camp = campaign(user, %{bible_id: wb.id})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
    assert html =~ ~r/<option value="#{wb.id}"[^>]*selected/

    view |> form("form[phx-change=select_world]", %{bible_id: ""}) |> render_change()
    assert Library.payload(Library.get(camp.id))[:bible_id] == nil
  end
end
