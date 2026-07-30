defmodule PolyphonyWeb.CampaignQuickBuildLiveTest do
  @moduledoc """
  The campaign editor's Quick Build (scaffold a world, cast & premise in one shot), the
  premise ✨ Expand button, and the edit links that jump into the world / character
  editors. Driven by the offline Mock so generation is deterministic.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  test "quick build scaffolds a world, cast, and premise onto the campaign",
       %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")

    view
    |> form("#quick-build", %{
      "world_seed" => "a rain-drowned harbor city",
      "character_seeds" => "a disgraced harbor-master\nthe collector who bought her past"
    })
    |> render_submit()

    html = render_async(view)

    payload = Library.payload(Library.get(camp.id))
    # A world and two characters are attached, and a premise was drafted.
    assert payload[:bible_id]
    assert length(payload[:character_ids]) == 2
    assert payload[:premise] not in [nil, ""]

    # The world is a real bible; the cast are :full characters linked to it.
    assert %WorldBible{} = Library.payload(Library.get(payload[:bible_id]))

    for id <- payload[:character_ids] do
      assert %CharacterSheet{status: :full, world_bible_id: wid} =
               Library.payload(Library.get(id))

      assert wid == payload[:bible_id]
    end

    # The cast now renders with edit links into the character editor.
    [cid | _] = payload[:character_ids]
    assert html =~ ~s(href="/authoring/character/#{cid}")
  end

  test "the world card links into the bible editor once a world is attached",
       %{conn: conn, user: user} do
    bible =
      Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: %WorldBible{name: "Bay"}})

    camp = campaign(user, %{bible_id: bible.id})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}")
    assert html =~ ~s(href="/authoring/bible/#{bible.id}")
  end

  test "expand deepens the campaign premise", %{conn: conn, user: user} do
    camp = campaign(user, %{premise: "A heist."})
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")

    view |> element("button[phx-click=expand_premise]") |> render_click()
    render_async(view)

    # The premise was regenerated (Mock lorem replaces the seed).
    assert Library.payload(Library.get(camp.id))[:premise] != "A heist."
  end
end
