defmodule PolyphonyWeb.LibraryAdminLiveTest do
  @moduledoc "V9 library ownership scoping + V13 admin authorization through the UI."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner, Moderation}
  alias Polyphony.Authoring.{CharacterSheet, Stub, WorldBible}

  defp at(html, str), do: html |> :binary.match(str) |> elem(0)

  describe "library (V9)" do
    setup :register_and_log_in_user

    test "creating a character makes a blank entry and jumps to its editor",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/library")

      # No name is required — Create navigates straight to the editor.
      assert {:error, {:live_redirect, %{to: to}}} =
               view |> form("form[phx-submit=new]", %{kind: "character"}) |> render_submit()

      assert [entry] = Library.list_for_owner(Owner.of(user))
      assert entry.kind == "character"
      assert to == "/authoring/character/#{entry.id}"
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

      # Filter to world bibles only. Match the entry card ("Name <span…") so the
      # world-filter dropdown's own option text doesn't count as a match.
      worlds =
        view |> form("form[phx-change=filter]", %{kind: "world_bible", q: ""}) |> render_change()

      assert worlds =~ "Neon Bay <span"
      refute worlds =~ "Mira Vale <span"

      # Search by name across all kinds.
      search =
        view |> form("form[phx-change=filter]", %{kind: "all", q: "mira"}) |> render_change()

      assert search =~ "Mira Vale <span"
      refute search =~ "Neon Bay <span"
    end

    test "characters and campaigns nest under their world; unassigned trail in No world",
         %{conn: conn, user: user} do
      owner = Owner.of(user)

      bay =
        Library.put(%{owner: owner, kind: "world_bible", payload: %WorldBible{name: "Neon Bay"}})

      Library.put(%{
        owner: owner,
        kind: "character",
        payload: %CharacterSheet{name: "BayNative", world_bible_id: bay.id, status: :full}
      })

      Library.put(%{
        owner: owner,
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "BayRun",
          bible_id: bay.id,
          character_ids: [],
          scenes: []
        }
      })

      Library.put(%{
        owner: owner,
        kind: "character",
        payload: %CharacterSheet{name: "FreeAgent", status: :full}
      })

      {:ok, _view, html} = live(conn, ~p"/library")

      # The world's character and campaign nest under its header; the unassigned
      # character lands in the trailing "No world" group.
      assert at(html, "Neon Bay") < at(html, "BayNative")
      assert at(html, "BayNative") < at(html, "No world")
      assert at(html, "No world") < at(html, "FreeAgent")
    end

    test "a pending stub character is badged; a full one is not", %{conn: conn, user: user} do
      owner = Owner.of(user)
      Library.put(%{owner: owner, kind: "character", payload: Stub.new("Ghost", "haunts her")})

      Library.put(%{
        owner: owner,
        kind: "character",
        payload: %CharacterSheet{name: "Mira", status: :full}
      })

      {:ok, _view, html} = live(conn, ~p"/library")

      assert html =~ "pending"
      # Only Ghost (the stub) is pending; Mira is full.
      assert Enum.count(Regex.scan(~r/badge stub">pending/, html)) == 1
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
