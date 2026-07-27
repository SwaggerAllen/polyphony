defmodule PolyphonyWeb.CharacterRelationshipsLiveTest do
  @moduledoc """
  Seeding relationships from the character editor: linking existing characters and
  stubbing not-yet-created ones (§B8).
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.CharacterSheet

  setup :register_and_log_in_user

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

  test "a relationship to a new name stubs that character on save", %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})

    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{target: "Ghost", descriptor: "haunts her"})
    |> render_submit()

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()

    # Mira now references Ghost...
    assert [%{target: "Ghost"}] = Library.payload(Library.get(mira.id)).relationships

    # ...and Ghost exists as a stub carrying the inbound relationship for promotion.
    ghost = find(user, "Ghost")
    assert ghost, "expected a stub character named Ghost"
    stub = Library.payload(ghost)
    assert stub.status == :stub
    assert [%{target: "Mira", descriptor: "haunts her"}] = stub.relationships
  end

  test "re-saving does not create a duplicate stub", %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    {:ok, view, _html} = live(conn, ~p"/authoring/character/#{mira.id}")

    view
    |> form("form[phx-submit=add_relationship]", %{target: "Ghost", descriptor: "x"})
    |> render_submit()

    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()
    view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()

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
