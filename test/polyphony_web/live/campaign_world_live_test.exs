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

    assert Library.payload(Library.get(camp.id))[:bible_id] == wb.id
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
