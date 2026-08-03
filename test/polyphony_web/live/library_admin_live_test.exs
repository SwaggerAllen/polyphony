defmodule PolyphonyWeb.LibraryAdminLiveTest do
  @moduledoc "V13 admin authorization through the UI."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Moderation

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
