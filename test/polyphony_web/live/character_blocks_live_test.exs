defmodule PolyphonyWeb.CharacterBlocksLiveTest do
  @moduledoc """
  The block-field editor on the character sheet: paragraphs add/remove/expand/
  regenerate, join into the plain-string field on save; plus AI relationship
  suggestions. Driven by the offline Mock so async generation is deterministic.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.CharacterSheet

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  test "a multi-paragraph field loads as separate blocks", %{conn: conn, user: user} do
    entry =
      character(user, %CharacterSheet{
        name: "Mira",
        backstory: "First para.\n\nSecond para.",
        status: :full
      })

    {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

    assert html =~ "First para."
    assert html =~ "Second para."
    # Two backstory blocks.
    assert length(Regex.scan(~r/name="b_backstory\[\]"/, html)) == 2
  end

  test "adding, editing, and saving blocks joins them with blank lines", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Mira", backstory: "", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

    # Start with one empty block; add a second.
    view |> element("button[phx-click=add_block][phx-value-field=backstory]") |> render_click()

    view
    |> form("form[phx-submit=save]", %{
      "name" => "Mira",
      "b_backstory" => ["Raised at sea.", "Lost her ship."]
    })
    |> render_submit()

    assert Library.payload(Library.get(entry.id)).backstory == "Raised at sea.\n\nLost her ship."
  end

  test "a pending stub's role is editable and persists on save", %{conn: conn, user: user} do
    entry =
      character(user, %CharacterSheet{
        name: "Bram",
        role: "old rival",
        status: :stub
      })

    {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

    # The pending stub exposes an editable role, pre-filled with the inherited one.
    assert html =~ "pending"
    assert html =~ ~s(name="role")

    # Correct the role, then save.
    view |> form("#stub-role-form") |> render_change(%{"role" => "estranged mentor"})
    view |> form("form[phx-submit=save]", %{"name" => "Bram"}) |> render_submit()

    saved = Library.payload(Library.get(entry.id))
    assert saved.role == "estranged mentor"
    # Saving finalizes the stub.
    assert saved.status == :full
  end

  test "a full character shows no pending role editor", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, _view, html} = live(conn, ~p"/authoring/character/#{entry.id}")
    refute html =~ ~s(name="role")
  end

  test "expand appends a paragraph without touching the others", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Mira", backstory: "Only para.", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

    view |> element("button[phx-click=expand_field][phx-value-field=backstory]") |> render_click()
    html = render_async(view)

    # Original stays; a second block now exists.
    assert html =~ "Only para."
    assert length(Regex.scan(~r/name="b_backstory\[\]"/, html)) == 2
  end

  test "regenerating one block rewrites just that block", %{conn: conn, user: user} do
    entry =
      character(user, %CharacterSheet{name: "Mira", backstory: "Placeholder.", status: :full})

    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

    view
    |> element(
      "button[phx-click='generate_block'][phx-value-field='backstory'][phx-value-index='0']"
    )
    |> render_click()

    html = render_async(view)
    refute html =~ ">Placeholder.</textarea>"
    assert length(Regex.scan(~r/name="b_backstory\[\]"/, html)) == 1
  end

  test "AI-suggested relationships are auto-added and stub on save", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

    before = Enum.count(Library.list_for_owner(Owner.of(user)), &(&1.kind == "character"))

    # Suggest adds directly to the list — no confirmation step.
    view |> element("button[phx-click=suggest_relationships]") |> render_click()
    html = render_async(view)
    assert html =~ "Added"
    assert html =~ "Remove"

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()
    # Drain the background reciprocal-generation the stubs trigger.
    render_async(view)

    after_count = Enum.count(Library.list_for_owner(Owner.of(user)), &(&1.kind == "character"))
    assert after_count > before
    assert Library.payload(Library.get(entry.id)).relationships != []
  end

  test "a relationship to an existing character links to its editor", %{conn: conn, user: user} do
    bram = character(user, %CharacterSheet{name: "Bram", status: :full})
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})

    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{target: "Bram", descriptor: "old friend"})
    |> render_submit()

    assert render(view) =~ ~s(href="/authoring/character/#{bram.id}")
  end

  test "a pending stub is finalized silently on save", %{conn: conn, user: user} do
    stub = Polyphony.Authoring.Stub.new("Ghost", "haunts her")
    entry = Library.put(%{owner: Owner.of(user), kind: "character", payload: stub})

    {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

    # It reads as pending, with no promote/accept machinery on screen.
    assert html =~ "pending"
    refute html =~ "phx-click=\"promote\""
    refute html =~ "phx-click=\"accept\""

    # Editing via the normal fields and saving finalizes it to :full.
    view |> form("form[phx-submit=save]", %{name: "Ghost"}) |> render_submit()

    assert Library.payload(Library.get(entry.id)).status == :full
    refute render(view) =~ "pending"
  end

  test "navigation is unguarded until there are unsaved edits", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, view, html} = live(conn, ~p"/authoring/character/#{entry.id}")

    # A freshly loaded sheet has nothing to lose — no confirmation armed.
    refute html =~ "data-confirm"

    # Any edit arms the leave-confirmation on the nav links.
    view
    |> element("button[phx-click=add_block][phx-value-field=backstory]")
    |> render_click()

    assert render(view) =~ "data-confirm=\"You have unsaved changes"
  end

  test "saving clears the unsaved-changes guard", %{conn: conn, user: user} do
    entry = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{entry.id}")

    view
    |> element("button[phx-click=add_block][phx-value-field=backstory]")
    |> render_click()

    assert render(view) =~ "data-confirm"

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()

    refute render(view) =~ "data-confirm"
  end
end
