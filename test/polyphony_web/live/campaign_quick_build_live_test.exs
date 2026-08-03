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

  # Quick Build is a first-run card rather than a tab: a one-shot that would be dead
  # weight from a campaign's second day. It opens on request.
  defp open_quick_build(view),
    do: view |> element("button[phx-click=toggle_quick_build]") |> render_click()

  test "quick build scaffolds a world, cast, and premise onto the campaign",
       %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")
    open_quick_build(view)

    # Add a second character row (starts with one), then submit both.
    view |> element("button[phx-click=add_seed]") |> render_click()

    view
    |> form("#quick-build", %{
      "world_seed" => "a rain-drowned harbor city",
      "char_seed" => ["a disgraced harbor-master", "the collector who bought her past"]
    })
    |> render_submit()

    # Quick Build is a multi-phase generation (world, then each character, then the
    # premise), so it wants more than the default 100ms even against the Mock.
    _html = render_async(view, 5_000)

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
    # The built cast shows on its own tab now, each row linking into its sheet.
    {:ok, _cast_view, cast_html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
    assert cast_html =~ ~s(href="/authoring/character/#{cid}")
  end

  test "character rows can be added and removed", %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")
    html = open_quick_build(view)

    # Starts with a single row.
    assert length(Regex.scan(~r/name="char_seed\[\]"/, html)) == 1

    view |> element("button[phx-click=add_seed]") |> render_click()
    view |> element("button[phx-click=add_seed]") |> render_click()
    assert length(Regex.scan(~r/name="char_seed\[\]"/, render(view))) == 3

    view
    |> element("button[phx-click=remove_seed][phx-value-index='1']")
    |> render_click()

    assert length(Regex.scan(~r/name="char_seed\[\]"/, render(view))) == 2
  end

  test "the world card links into the bible editor once a world is attached",
       %{conn: conn, user: user} do
    bible =
      Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: %WorldBible{name: "Bay"}})

    camp = campaign(user, %{bible_id: bible.id})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
    assert html =~ ~s(href="/authoring/bible/#{bible.id}")
  end

  test "expand deepens the campaign premise", %{conn: conn, user: user} do
    camp = campaign(user, %{premise: "A heist."})
    # Premise is its own tab now, and sits after Cast — the pitch is written from
    # the cast, so ordering it earlier invites writing it twice.
    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=premise")

    view |> element("button[phx-click=expand_premise]") |> render_click()
    render_async(view)

    # The premise was regenerated (Mock lorem replaces the seed).
    assert Library.payload(Library.get(camp.id))[:premise] != "A heist."
  end
end
