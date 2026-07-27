defmodule PolyphonyWeb.LibraryAdminLiveTest do
  @moduledoc "V9 library ownership scoping + V13 admin authorization through the UI."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner, Moderation}

  describe "library (V9)" do
    setup :register_and_log_in_user

    test "creating a character shows it, scoped to the owner", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/library")

      view
      |> form("form[phx-submit=new]", %{kind: "character", name: "Mira"})
      |> render_submit()

      assert render(view) =~ "Mira"
      # It really is owned by this user (via the Owner indirection).
      assert [entry] = Library.list_for_owner(Owner.of(user))
      assert entry.kind == "character"
    end

    test "another user's library is not shown", %{conn: conn} do
      other = user_fixture()
      Library.put(%{owner: Owner.of(other), kind: "character", payload: %{name: "Secret"}})

      {:ok, _view, html} = live(conn, ~p"/library")
      refute html =~ "Secret"
    end

    test "filtering by kind and searching by name narrows the list", %{conn: conn, user: user} do
      owner = Owner.of(user)
      Library.put(%{owner: owner, kind: "character", payload: %{name: "Mira Vale"}})
      Library.put(%{owner: owner, kind: "world_bible", payload: %{name: "Neon Bay"}})

      {:ok, view, html} = live(conn, ~p"/library")
      assert html =~ "Mira Vale" and html =~ "Neon Bay"

      # Filter to world bibles only.
      worlds =
        view |> form("form[phx-change=filter]", %{kind: "world_bible", q: ""}) |> render_change()

      assert worlds =~ "Neon Bay"
      refute worlds =~ "Mira Vale"

      # Search by name across all kinds.
      search =
        view |> form("form[phx-change=filter]", %{kind: "all", q: "mira"}) |> render_change()

      assert search =~ "Mira Vale"
      refute search =~ "Neon Bay"
    end
  end

  describe "admin (V13)" do
    test "a non-admin cannot reach the admin console", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "an admin sees the report queue", %{conn: conn} do
      admin = user_fixture(%{role: "superadmin"})
      reporter = user_fixture()
      owner = user_fixture()

      {:ok, _report} =
        Moderation.file_report(reporter, %{
          item_type: "library_entry",
          item_id: 1,
          owner_id: owner.id,
          reason: "harassment",
          detail: "please look"
        })

      conn = log_in_user(conn, admin)
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "Open reports"
      assert html =~ "harassment"
    end
  end
end
