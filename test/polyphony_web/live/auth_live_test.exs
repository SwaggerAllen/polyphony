defmodule PolyphonyWeb.AuthLiveTest do
  @moduledoc "V11: sign-up gates + magic-link sign-in through the UI."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Accounts

  test "the home page renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Polyphony"
    assert html =~ "Sign in"
  end

  test "the first sign-up becomes the superadmin and is sent to verify", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/signup")

    result =
      view
      |> form("form[phx-submit=register]", %{
        email: "boss@x.io",
        username: "bossuser",
        attest: "true",
        consent: "true"
      })
      |> render_submit()

    assert {:error, {:redirect, %{to: "/auth/verify/" <> _}}} = result
    assert Accounts.get_by_username("bossuser").role == "superadmin"
  end

  test "sign-up without attestation is refused", %{conn: conn} do
    # Make an existing account first so this one isn't the bootstrap superadmin.
    user_fixture()
    {:ok, view, _html} = live(conn, ~p"/signup")

    html =
      view
      |> form("form[phx-submit=register]", %{email: "x@x.io", username: "xuser", consent: "true"})
      |> render_submit()

    assert html =~ "18 or older"
  end

  test "requesting a magic link for an existing account surfaces the dev link", %{conn: conn} do
    user = user_fixture(%{email: "known@x.io"})
    {:ok, view, _html} = live(conn, ~p"/login")

    html = view |> form("form[phx-submit=send]", %{email: user.email}) |> render_submit()
    assert html =~ "on its way"
    assert html =~ "click to sign in"
  end

  test "an authed area redirects a signed-out visitor to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/library")
  end
end
