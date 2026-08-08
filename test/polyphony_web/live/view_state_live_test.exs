defmodule PolyphonyWeb.ViewStateLiveTest do
  @moduledoc """
  Where you were is in the URL, so coming back puts you back.

  The third of the three places page state used to be lost. Autosave keeps the writing
  and the build job keeps the work; this keeps the *view* — which panel, drawer or
  picker was open. All three had the same cause: a LiveView process ends when its socket
  does, and everything held only in its assigns ends with it.

  The URL is the store because it is the one the browser already keeps for us. It
  survives a reconnect without a schema, it is shareable, and it makes Back close what's
  open — which on a phone is the gesture people reach for anyway, and which no amount of
  socket state can give you.

  So each test opens something, then mounts the resulting URL **fresh**, as a reconnect
  would. Asserting on the same socket would prove only that `assign` works.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Group, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.Authoring.WorldBible.Entry

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp entry(user, kind, payload),
    do: Library.put(%{owner: Owner.of(user), kind: kind, payload: payload})

  # What a reconnect does: throw the process away and mount the URL again.
  defp remount(conn, view) do
    path = assert_patch(view)
    {:ok, _view, html} = live(conn, path)
    {path, html}
  end

  describe "the world bible" do
    test "an open drawer survives being mounted again", %{conn: conn, user: user} do
      entry = entry(user, "world_bible", %WorldBible{name: "Saltmarch"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view |> element("button[phx-click=drawer][phx-value-section=cover]") |> render_click()

      {path, html} = remount(conn, view)
      assert path =~ "drawer=cover"
      assert html =~ "About the cover"
    end

    test "so does an open audience picker, on the item it was opened from",
         %{conn: conn, user: user} do
      entry(user, "character", %CharacterSheet{name: "Sable Quist"})

      entry =
        entry(user, "world_bible", %WorldBible{
          name: "Saltmarch",
          starting_canon: [
            %Entry{statement: "The public one."},
            %Entry{statement: "The tide bell answers to something.", concealed: true}
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element(
        "button[phx-click=open_audience][phx-value-field=starting_canon][phx-value-index='1']"
      )
      |> render_click()

      {path, html} = remount(conn, view)

      # The index matters as much as the fact it's open: reopening on the wrong item
      # would be worse than not reopening at all.
      assert path =~ "audience=starting_canon%3A1"
      assert html =~ "Who starts out knowing"
      assert html =~ "The tide bell answers to something."
    end

    test "a field name from the query string is checked, not trusted",
         %{conn: conn, user: user} do
      entry = entry(user, "world_bible", %WorldBible{name: "Saltmarch"})

      # Default-deny, the same instinct as everywhere else: an unknown field is no
      # picker rather than a crash — and nothing here ever mints an atom from a URL.
      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}?audience=nonsense:0")
      refute html =~ "Who starts out knowing"

      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}?audience=rules:notanumber")
      refute html =~ "Who starts out knowing"
    end

    test "closing it takes it back out of the URL", %{conn: conn, user: user} do
      entry = entry(user, "world_bible", %WorldBible{name: "Saltmarch"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view |> element("button[phx-click=drawer][phx-value-section=cover]") |> render_click()
      assert assert_patch(view) =~ "drawer=cover"

      # The drawer's own × is the same event, so once it's open two controls match.
      view |> element("button[aria-label='Close About the cover']") |> render_click()
      refute assert_patch(view) =~ "drawer="
    end
  end

  describe "the character sheet" do
    test "an open add-panel survives being mounted again", %{conn: conn, user: user} do
      entry = entry(user, "character", %CharacterSheet{name: "Wren", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=panel][phx-value-panel=fact]") |> render_click()

      {path, html} = remount(conn, view)
      assert path =~ "panel=fact"
      assert html =~ ~s(phx-submit="add_fact")
    end

    test "so does the picker, on the fact it was opened from", %{conn: conn, user: user} do
      entry(user, "character", %CharacterSheet{name: "Sable Quist"})

      entry =
        entry(user, "character", %CharacterSheet{
          name: "Wren",
          status: :full,
          facts: [
            %Fact{statement: "Public knowledge."},
            %Fact{statement: "She signs for the cargo.", concealed: true}
          ]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=open_audience][phx-value-index='1']") |> render_click()

      {path, html} = remount(conn, view)
      assert path =~ "audience=1"
      assert html =~ "She signs for the cargo."
    end
  end

  describe "a group" do
    test "an open panel survives being mounted again", %{conn: conn, user: user} do
      entry = Groups.create(Owner.of(user), %Group{name: "The Tidewatch", campaign_id: "camp"})
      {:ok, view, _html} = live(conn, ~p"/authoring/group/#{entry.id}")

      view |> element("button[phx-click=panel][phx-value-panel=facts]") |> render_click()

      {path, html} = remount(conn, view)
      assert path =~ "panel=facts"
      assert html =~ ~s(id="group-fact-form")
    end
  end
end
