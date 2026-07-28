defmodule PolyphonyWeb.CharacterRelationshipsLiveTest do
  @moduledoc """
  Seeding relationships from the character editor: linking existing characters and
  stubbing not-yet-created ones (§B8).
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

  defp characters(user),
    do: Library.list_for_owner(Owner.of(user)) |> Enum.filter(&(&1.kind == "character"))

  defp find(user, name), do: Enum.find(characters(user), &(Library.payload(&1).name == name))

  test "a relationship to an existing character links without stubbing", %{conn: conn, user: user} do
    character(user, %CharacterSheet{name: "Bram", status: :full})
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})

    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{target: "Bram", descriptor: "old friend"})
    |> render_submit()

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()

    rels = Library.payload(Library.get(mira.id)).relationships
    assert [%{target: "Bram", descriptor: "old friend"}] = rels
    # No stub created — still just Bram + Mira.
    assert length(characters(user)) == 2
  end

  test "a new name stubs on save, with an asymmetrical reciprocal regard",
       %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})

    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{
      target: "Ghost",
      descriptor: "estranged mentor"
    })
    |> render_submit()

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()
    # Drain the background reciprocal-generation before inspecting the stub.
    render_async(view)

    # Mira now references Ghost as she described them...
    assert [%{target: "Ghost", descriptor: "estranged mentor"}] =
             Library.payload(Library.get(mira.id)).relationships

    # ...and Ghost exists as a stub whose role is that regard, but whose OWN regard
    # back toward Mira is a distinct, generated reciprocal (not a copy).
    ghost = find(user, "Ghost")
    assert ghost, "expected a stub character named Ghost"
    stub = Library.payload(ghost)
    assert stub.status == :stub
    assert stub.role == "estranged mentor"

    assert [%{target: "Mira"} = back] = stub.relationships
    # The reciprocal field records how Mira regards Ghost; the descriptor (Ghost→Mira)
    # is the generated, asymmetrical regard — different from Mira's.
    assert back.reciprocal == "estranged mentor"
    assert is_binary(back.descriptor) and back.descriptor != ""
    refute back.descriptor == "estranged mentor"
  end

  test "a stubbed character inherits the generating character's world", %{conn: conn, user: user} do
    world =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %Polyphony.Authoring.WorldBible{name: "Neon Bay"}
      })

    mira = character(user, %CharacterSheet{name: "Mira", world_bible_id: world.id, status: :full})

    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    # The editor loads with Mira's world already selected.
    view
    |> form("form[phx-submit=add_relationship]", %{target: "Ghost", descriptor: "haunts her"})
    |> render_submit()

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()
    render_async(view)

    ghost = find(user, "Ghost")
    assert ghost, "expected a stub character named Ghost"
    assert Library.payload(ghost).world_bible_id == world.id
  end

  test "re-saving does not create a duplicate stub", %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{target: "Ghost", descriptor: "x"})
    |> render_submit()

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()
    render_async(view)
    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()
    render_async(view)

    assert Enum.count(characters(user), &(Library.payload(&1).name == "Ghost")) == 1
  end

  test "removing a relationship drops it before save", %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{target: "Ghost", descriptor: "x"})
    |> render_submit()

    view |> element("button[phx-click=remove_relationship]") |> render_click()
    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()

    assert Library.payload(Library.get(mira.id)).relationships == []
    refute find(user, "Ghost")
  end
end
