defmodule PolyphonyWeb.InfoDrawerLiveTest do
  @moduledoc """
  The `i` beside a section header, and where its answer appears.

  It opened an **inline** panel, on screens that are one long scroll by design — so the
  explanation landed wherever it happened to sit in the document, routinely a screen or
  two below the control that asked for it. Nothing acknowledged the press, the close
  control was off-screen, and the answer to *what does this mean* arrived somewhere you
  had to go looking for. `Kit.overlay/1`'s own docs describe exactly this failure; the
  three drawers predated it and were three copies of the same markup.

  So there is now one `Kit.info_drawer/1` built on the overlay, and the campaign's
  publishing `i` — which had **no handler at all**, and killed the LiveView with a
  `FunctionClauseError` — has one too.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  setup :register_and_log_in_user

  defp character(user),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full}
      })

  defp world(user),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Saltmarch", rules: [], starting_canon: []}
      })

  defp campaign(user),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []}
      })

  describe "on the character sheet" do
    test "the answer opens over the screen, not somewhere down it",
         %{conn: conn, user: user} do
      entry = character(user)
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      # The `i` itself is `aria-label="About facts"`, so the dialog is what to look for.
      refute html =~ ~s(aria-modal="true")

      html =
        view
        |> element(~s(button[phx-click="drawer"][phx-value-section="facts"]))
        |> render_click()

      # `position:fixed`, so it cannot land below the fold no matter how long the sheet
      # is — and the scrim and Escape are two of the three ways back out.
      assert html =~ ~s(class="scrim")
      assert html =~ ~s(phx-key="Escape")
      assert html =~ ~s(aria-modal="true" aria-label="About facts")
    end

    test "the × closes it, and so does the scrim", %{conn: conn, user: user} do
      entry = character(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element(~s(button[phx-click="drawer"][phx-value-section="cover"])) |> render_click()

      # One drawer at a time, so the way out needs no section on it.
      cleared = render_click(view, "close_drawer", %{})
      refute cleared =~ ~s(class="scrim")
      refute cleared =~ ~s(aria-modal="true")
    end

    test "the long ones scroll inside themselves", %{conn: conn, user: user} do
      entry = character(user)
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html =
        view
        |> element(~s(button[phx-click="drawer"][phx-value-section="pushed"]))
        |> render_click()

      # The head holds and the body scrolls, so the way out is never the thing you have
      # to scroll to find.
      assert html =~ ~s(class="modal-body")
    end
  end

  test "the world bible's drawers moved with it", %{conn: conn, user: user} do
    entry = world(user)
    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    # Two sections share the secrets drawer — rules and starting canon — so this is
    # deliberately the first of them rather than a unique selector.
    html = render_click(view, "drawer", %{"section" => "secrets"})

    assert html =~ ~s(class="scrim")
    assert html =~ ~s(aria-modal="true" aria-label="About secrets")
  end

  test "the publishing i explains publishing instead of killing the page",
       %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")

    # It had no `handle_event` clause at all. A `phx-click` with nothing to match raises
    # `FunctionClauseError` and takes the LiveView with it — so the one control whose
    # whole job is explaining the screen left a page you could only reload out of.
    refute html =~ ~s(aria-modal="true")

    html = view |> element("button[phx-click=publish_help]") |> render_click()

    assert html =~ ~s(aria-modal="true" aria-label="About publishing")
    assert html =~ ~s(class="scrim")
    # And it says the thing the screen's own comment says: two questions, not a ladder.
    assert html =~ "two separate questions"

    refute render_click(view, "publish_help", %{}) =~ ~s(aria-modal="true")
  end
end
