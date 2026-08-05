defmodule PolyphonyWeb.SheetLayoutLiveTest do
  @moduledoc """
  Where the character sheet puts the two things it was hiding: who this person is, and
  the button that finishes them.

  **Name and pronouns were last.** They sat under the groups section, at the bottom of a
  page with five prose fields, the facts, the relationships and both pressure lists above
  them — filed there because they happened to share a row with the Save button. They are
  the only fields on the sheet that are *identity* rather than description; everything
  else is written about the person these two name.

  **Save is not optional, and nothing said so.** The prose has autosaved for a while
  (`Autosave` — every edit and every generation calls `touch/1`), so "unsaved changes"
  would be a lie most of the time. What only a deliberate Save does is promote a stub to
  `:full`, and `SceneControl` refuses anything that isn't — so a sheet written entirely
  by "✦ Write every field" could be complete, saved, and still uncastable, with the one
  control that changed that being the last thing on the page. The bar says which of those
  two situations you are in, and doesn't scroll away.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.CharacterSheet

  setup :register_and_log_in_user

  defp character(user, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: "Wren", status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp at(html, needle) do
    case :binary.match(html, needle) do
      {i, _} -> i
      :nomatch -> nil
    end
  end

  describe "identity comes first" do
    test "the name field is above every field written about them", %{conn: conn, user: user} do
      entry = character(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      name = at(html, ~s(id="sheet-name"))
      pronouns = at(html, ~s(id="sheet-pronouns"))
      cover = at(html, ~s(id="cover-text"))
      groups = at(html, ~s(id="groups"))

      assert name && pronouns && cover && groups
      assert name < pronouns
      assert pronouns < cover
      # Where it used to be: after everything, including the groups list.
      assert name < groups
    end

    test "the jump bar leads with it too", %{conn: conn, user: user} do
      entry = character(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # The jump bar is the only navigation a one-long-scroll screen has, so a section
      # that isn't a stop is a section you have to know is there.
      assert at(html, ~s(href="#name")) < at(html, ~s(href="#cover"))
    end

    test "editing them still saves — they did not leave the form", %{conn: conn, user: user} do
      entry = character(user, %{name: "Wren", pronouns: nil})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("#sheet-form", %{name: "Wren Ashgrove", pronouns: "she / her"})
      |> render_submit()

      sheet = Library.payload(Library.get(entry.id))
      assert sheet.name == "Wren Ashgrove"
      assert sheet.pronouns == "she / her"
    end
  end

  describe "the save bar" do
    test "is outside the scrolling region, so it can't be scrolled past",
         %{conn: conn, user: user} do
      entry = character(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # A sibling of the scroll container rather than something inside it — the same
      # shape play's say-bar has, and no new kit primitive to hold the viewport. Two
      # things say so and both are load-bearing: `shrink-0` is what stops the flex
      # column giving it away to the scroller, and `form="sheet-form"` is only needed
      # at all *because* the button is outside the form it submits.
      assert html =~ ~s(class="shrink-0 px-4 py-3 flex items-center gap-2")
      assert html =~ ~s(form="sheet-form")

      # And it comes after the region that scrolls, not within it.
      assert at(html, ~s(form="sheet-form")) > at(html, ~s(class="flex-1 min-h-0 overflow-y-auto))
    end

    test "a stub is told that saving is what finishes it", %{conn: conn, user: user} do
      entry = character(user, %{status: :stub})
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # The thing that was invisible. `SceneControl` refuses a non-`:full` character, so
      # a sheet can be complete, written and saved, and still not castable.
      assert html =~ "saving is what makes them castable"
      assert html =~ "Save &amp; finish"
    end

    test "a finished sheet says what is actually true instead", %{conn: conn, user: user} do
      entry = character(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # "Unsaved changes" would be a lie: the prose autosaves. Claiming otherwise
      # teaches an author to distrust a warning that is usually wrong.
      refute html =~ "saving is what makes them castable"
      assert html =~ "Everything here is saved as you write."
      assert html =~ ">Save<" or html =~ "Save\n"
    end

    test "saving from it promotes the stub, which is the whole point",
         %{conn: conn, user: user} do
      entry = character(user, %{status: :stub, premise: "A harbour-master."})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html = view |> form("#sheet-form") |> render_submit()

      assert Library.payload(Library.get(entry.id)).status == :full
      # And the bar changes its mind with the sheet, rather than still nagging.
      refute html =~ "saving is what makes them castable"
      assert html =~ "✓ Saved"
    end
  end

  describe "\"Writing this sheet\"" do
    test "is near the top, because it decides how the rest gets written",
         %{conn: conn, user: user} do
      entry = character(user)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      pane = at(html, "Writing this sheet")
      cover = at(html, ~s(id="cover-text"))
      facts = at(html, ~s(id="facts"))

      assert pane && cover && facts
      # Tier is what puts a character in every scene's context or only in the scenes
      # they appear in. Answering that after writing the sheet is answering it too late.
      assert pane < cover
      assert pane < facts
    end

    test "the world picker is gone, and the world is still stated",
         %{conn: conn, user: user} do
      wb =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %Polyphony.Authoring.WorldBible{name: "Saltmarch"}
        })

      entry = character(user)

      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "Camp",
          character_ids: [entry.id],
          bible_id: wb.id,
          scenes: []
        }
      })

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      refute html =~ ~s(id="world-select")
      refute html =~ ~s(phx-change="select_world")
      assert html =~ "Saltmarch"
    end

    test "what's left is the tier selector", %{conn: conn, user: user} do
      entry = character(user)
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      assert html =~ ~s(phx-click="set_tier")

      view
      |> element(~s(button[phx-click="set_tier"][phx-value-tier="incidental"]))
      |> render_click()

      # It saves on tap rather than with the form: a set of pills has no obvious apply.
      assert Library.payload(Library.get(entry.id)).tier == :incidental
    end
  end
end
