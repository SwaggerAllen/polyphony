defmodule PolyphonyWeb.AuthoringAutofillLiveTest do
  @moduledoc """
  The editor auto-generation UI (§15): a free-text brief that fills every field, and
  a per-field ✨ button. Driven by the offline Mock so async generation is
  deterministic; `render_async/1` awaits the `start_async` task.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Boundary

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, sheet) do
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp world(user, bible) do
    Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})
  end

  describe "character sheet editor" do
    test "the brief fills every field", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", status: :full})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a jaded harbor detective"})
      |> render_submit()

      html = render_async(view)
      # The name field, empty at mount, now carries generated content...
      assert Regex.match?(~r/name="name" value="[^"]+"/, html)
      # ...and the premise block is no longer empty.
      refute html =~ ~r/name="b_premise\[\]"[^>]*>\s*<\/textarea>/
    end

    test "a per-field button generates just that field", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Mara", premise: "", status: :full})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> element("button[phx-click=generate_field][phx-value-field=premise]")
      |> render_click()

      html = render_async(view)
      # The premise block (empty at mount) now has content; the name is untouched.
      refute html =~ ~r/name="b_premise\[\]"[^>]*>\s*<\/textarea>/
      assert html =~ ~s(value="Mara")
    end

    test "generation only populates the form — saving persists it", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", premise: "", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a smuggler"})
      |> render_submit()

      render_async(view)
      # Not persisted yet — generation only populates the form.
      assert Library.payload(Library.get(entry.id)).premise in [nil, ""]

      html = view |> form("form[phx-submit=save]") |> render_submit()
      refute Library.payload(Library.get(entry.id)).premise in [nil, ""]
      # Confirmation shows inline by the button (not only the top-of-page flash).
      assert html =~ "✓ Saved"
    end
  end

  describe "inline save confirmation" do
    test "the world bible editor confirms next to the Save button", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "Old", rules: [], starting_canon: []})
      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      refute html =~ "✓ Saved"

      saved = view |> form("form[phx-submit=save]", %{name: "Newname"}) |> render_submit()
      assert saved =~ "✓ Saved"

      # Editing again clears the confirmation so it can't read as stale.
      changed = view |> form("form[phx-submit=save]", %{name: "Newer"}) |> render_change()
      refute changed =~ "✓ Saved"
    end
  end

  describe "world seeding on the character editor" do
    test "the world selector lists the author's world bibles", %{conn: conn, user: user} do
      world(user, %WorldBible{name: "Neon Bay", setting: "a drowned port"})
      entry = character(user, %CharacterSheet{name: "", status: :full})

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      assert html =~ "Neon Bay"
    end

    test "selecting a world persists the link on save", %{conn: conn, user: user} do
      wb = world(user, %WorldBible{name: "Neon Bay", setting: "a drowned port"})
      entry = character(user, %CharacterSheet{name: "", status: :full})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-change=select_world]", %{world_id: to_string(wb.id)})
      |> render_change()

      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()

      assert Library.payload(Library.get(entry.id)).world_bible_id == wb.id
    end

    test "a persisted world link is preselected on mount", %{conn: conn, user: user} do
      wb = world(user, %WorldBible{name: "Neon Bay"})
      entry = character(user, %CharacterSheet{name: "Rell", status: :full, world_bible_id: wb.id})

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      assert html =~ ~r/<option value="#{wb.id}"[^>]*selected/
    end
  end

  describe "boundaries (§A3)" do
    test "adding a boundary and saving persists the full structure", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Rell", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html =
        view
        |> form("form[phx-submit=add_boundary]", %{
          topic: "physical intimacy",
          stance: "conditional",
          condition: "she trusts them",
          on_pressure: "she withdraws",
          category: "sexual"
        })
        |> render_submit()

      assert html =~ "physical intimacy"
      assert html =~ "held until earned"

      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()

      assert [%Boundary{} = b] = Library.payload(Library.get(entry.id)).boundaries
      assert b.topic == "physical intimacy"
      assert b.stance == :conditional
      assert b.condition == "she trusts them"
      assert b.on_pressure == "she withdraws"
      assert b.category == :sexual
    end

    test "a stored boundary renders and can be removed before saving", %{conn: conn, user: user} do
      sheet = %CharacterSheet{
        name: "Rell",
        status: :full,
        boundaries: [%Boundary{topic: "killing", stance: :closed}]
      }

      entry = character(user, sheet)
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      assert html =~ "killing"
      assert html =~ "a hard line"

      view
      |> element("button[phx-click=remove_boundary][phx-value-index='0']")
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()
      assert Library.payload(Library.get(entry.id)).boundaries == []
    end

    test "an empty topic is rejected", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Rell", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html =
        view
        |> form("form[phx-submit=add_boundary]", %{topic: "  ", stance: "closed"})
        |> render_submit()

      assert html =~ "Give the boundary a topic"
    end

    # The metered suggestion write to the cost ledger logs a sandbox-ownership error from
    # the async task (best-effort; a no-op in prod with a real connection) — capture it.
    @tag :capture_log
    test "✨ Suggest adds AI-proposed boundaries to the list", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Rell", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view |> element("button[phx-click=suggest_boundaries]") |> render_click()
      html = render_async(view)

      # A suggested boundary landed (the Mock returns a conditional one held-until-earned).
      assert html =~ "held until earned"

      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()
      assert Library.payload(Library.get(entry.id)).boundaries != []
    end

    test "Boundaries renders before Relationships", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Rell", status: :full})
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      bnd = :binary.match(html, "Boundaries") |> elem(0)
      rel = :binary.match(html, "Relationships") |> elem(0)
      assert bnd < rel
    end
  end

  describe "generate all fields" do
    @tag :capture_log
    test "also populates boundaries and relationships when empty", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", status: :full})
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # Both cards start empty.
      assert html =~ "No relationships yet."
      assert html =~ "No boundaries yet."

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a wary harbor smuggler"})
      |> render_submit()

      # First await settles the fields task, whose completion *chains* the relationship
      # and boundary suggestions; the second await settles those.
      render_async(view)
      html = render_async(view)

      refute html =~ "No relationships yet."
      refute html =~ "No boundaries yet."
    end
  end

  describe "world bible editor" do
    test "the brief fills every field including the list-typed ones", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "", rules: [], starting_canon: []})

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a drowned neon city"})
      |> render_submit()

      html = render_async(view)
      # A prose field (setting) and a list field (rules) both fill as blocks.
      refute html =~ ~r/name="b_setting\[\]"[^>]*>\s*<\/textarea>/
      refute html =~ ~r/name="b_rules\[\]"[^>]*>\s*<\/textarea>/
    end
  end
end
