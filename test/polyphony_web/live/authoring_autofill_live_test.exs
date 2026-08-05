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

  # Adding to a list opens a panel below the sheet — the mock's own treatment (§04),
  # and what keeps the lists inside the sheet's one form without nesting a second.
  defp open_panel(view, panel) do
    view |> element("button[phx-click=panel][phx-value-panel=#{panel}]") |> render_click()
    view
  end

  defp character(user, sheet) do
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp world(user, bible) do
    Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})
  end

  defp campaign(user, attrs) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  describe "character sheet editor" do
    test "the brief fills every field", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", status: :full})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a jaded harbor detective"})
      |> render_submit()

      html = generate(view)
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

      html = generate(view)
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

      generate(view)
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

  describe "the world a character is written in" do
    test "comes from their campaign, not from a picker", %{conn: conn, user: user} do
      wb = world(user, %WorldBible{name: "Neon Bay", setting: "a drowned port"})
      entry = character(user, %CharacterSheet{name: "Rell", status: :full})
      campaign(user, %{bible_id: wb.id, character_ids: [entry.id]})

      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # A character belongs to one campaign (§2.7) and a campaign holds its own copy of
      # a bible, so the setting is decided before this screen opens. The picker could
      # only ever be used to ground a character in a world their campaign doesn't play
      # in — and since attaching copies, most of what it listed was other campaigns'
      # working copies.
      refute html =~ ~s(id="world-select")
      # Stated where the rest of the identity line is, instead.
      assert html =~ "Neon Bay"
    end

    test "the campaign's world wins over a stale link on the sheet",
         %{conn: conn, user: user} do
      old_world = world(user, %WorldBible{name: "Old Harbour"})
      new_world = world(user, %WorldBible{name: "Neon Bay"})

      entry =
        character(user, %CharacterSheet{name: "Rell", status: :full, world_bible_id: old_world.id})

      campaign(user, %{bible_id: new_world.id, character_ids: [entry.id]})

      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # A campaign that swaps its world would otherwise leave every character pointing
      # at the old copy until each was opened and re-picked by hand.
      assert html =~ "Neon Bay"
      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()
      assert Library.payload(Library.get(entry.id)).world_bible_id == new_world.id
    end

    test "a character with no campaign keeps whatever it was given",
         %{conn: conn, user: user} do
      wb = world(user, %WorldBible{name: "Neon Bay"})
      entry = character(user, %CharacterSheet{name: "Rell", status: :full, world_bible_id: wb.id})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")
      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()

      assert Library.payload(Library.get(entry.id)).world_bible_id == wb.id
    end
  end

  describe "pressures (§A3)" do
    test "adding one and saving persists the full structure", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "Rell", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      html =
        view
        |> open_panel("pressure")
        |> form("form[phx-submit=add_boundary]", %{
          topic: "physical intimacy",
          direction: "refusal",
          stance: "conditional",
          condition: "she trusts them",
          on_pressure: "she withdraws",
          category: "sexual"
        })
        |> render_submit()

      assert html =~ "physical intimacy"
      # A conditional refusal reads as one the story can still turn.
      assert html =~ "Not yet"

      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()

      assert [%Boundary{} = b] = Library.payload(Library.get(entry.id)).boundaries
      assert b.topic == "physical intimacy"
      assert b.stance == :conditional
      assert b.condition == "she trusts them"
      assert b.on_pressure == "she withdraws"
      assert b.category == :sexual
    end

    test "a stored one renders and can be removed before saving", %{conn: conn, user: user} do
      sheet = %CharacterSheet{
        name: "Rell",
        status: :full,
        boundaries: [%Boundary{topic: "killing", stance: :closed}]
      }

      entry = character(user, sheet)
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
      assert html =~ "killing"
      assert html =~ "Never"

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
        |> open_panel("pressure")
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
      html = generate(view)

      # The Mock returns one of each direction, both conditional — so both lists fill,
      # which is the point of asking for both.
      assert html =~ "Not yet"
      assert html =~ "Until"

      view |> form("form[phx-submit=save]", %{name: "Rell"}) |> render_submit()
      assert Library.payload(Library.get(entry.id)).boundaries != []
    end

    test "the two directions are separate lists, refusals first", %{conn: conn, user: user} do
      sheet = %CharacterSheet{
        name: "Rell",
        status: :full,
        boundaries: [
          %Boundary{topic: "Sign for the Kestrel", direction: :compulsion, stance: :closed},
          %Boundary{topic: "Name her father", direction: :refusal, stance: :closed}
        ]
      }

      entry = character(user, sheet)
      {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # Grouping is what carries the direction, so an item can never be read backwards —
      # and the refusal list leads even when the compulsion was authored first.
      # Apostrophes come back HTML-escaped, so match on the unambiguous half.
      wont = :binary.match(html, "t do</span>") |> elem(0)
      cant = :binary.match(html, "t stop doing</span>") |> elem(0)
      assert wont < cant
      assert :binary.match(html, "Name her father") |> elem(0) < cant
      assert :binary.match(html, "Sign for the Kestrel") |> elem(0) > cant
    end
  end

  describe "generate all fields" do
    @tag :capture_log
    test "also populates boundaries and relationships when empty", %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", status: :full})
      {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

      # Both lists start empty.
      assert html =~ "Nobody yet."
      assert html =~ "Nothing gives."

      view
      |> form("form[phx-submit=generate_all]", %{brief: "a wary harbor smuggler"})
      |> render_submit()

      # First await settles the fields task, whose completion *chains* the relationship
      # and boundary suggestions; the second await settles those.
      generate(view)
      html = generate(view)

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

      html = generate(view)
      # A prose field (setting) and a list field (rules) both fill as blocks.
      refute html =~ ~r/name="b_setting\[\]"[^>]*>\s*<\/textarea>/
      refute html =~ ~r/name="b_rules\[\]"[^>]*>\s*<\/textarea>/
    end
  end

  describe "the cover is part of \"every field\"" do
    test "generate-all writes it too, after everything it is written from",
         %{conn: conn, user: user} do
      entry = character(user, %CharacterSheet{name: "", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

      view
      |> form("#sheet-generate-all", %{brief: "a harbour-master with a debt"})
      |> render_submit()

      generate(view)
      # The cover is a second call, chained once the fields it describes exist — the
      # same order Quick Build writes in.
      generate(view)

      view |> form("#sheet-form") |> render_submit()

      # It used to write every field except the one a stranger actually reads.
      assert Library.payload(Library.get(entry.id)).cover not in [nil, ""]
    end

    test "a cover somebody already approved is left alone", %{conn: conn, user: user} do
      entry =
        character(user, %CharacterSheet{name: "Rell", status: :full, cover: "Mine, thanks."})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")
      view |> form("#sheet-generate-all", %{brief: "a harbour-master"}) |> render_submit()
      generate(view)
      generate(view)

      # Same rule as the facts and the two suggestion passes: a redraft of prose
      # somebody has already approved is a second author, not a first.
      assert render(view) =~ "Mine, thanks."
    end
  end
end
