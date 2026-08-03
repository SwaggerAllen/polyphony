defmodule PolyphonyWeb.AuthLiveTest do
  @moduledoc """
  Getting in, as `ux/polyphony-settings-auth.html` §03 draws it.

  The one that carries weight: **18+ is eligibility, not a content setting**, so an
  unchecked box ends the signup rather than limiting it — and the screen it ends on has
  no retry, because a door that reopens on the same screen isn't a door.

  And the half nobody sees: turning somebody away must not create a row about them, and
  must not burn the invite that brought them.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Accounts

  test "the home page renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Polyphony"
    assert html =~ "Sign in"
  end

  describe "signing up" do
    test "the first sign-up becomes the superadmin and is sent to verify", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/signup")
      assert html =~ "You&#39;re the first"

      view |> element("[phx-click=toggle][phx-value-field=attest]") |> render_click()
      view |> element("[phx-click=toggle][phx-value-field=consent]") |> render_click()

      result =
        view
        |> form("form[phx-submit=register]", %{email: "boss@x.io", username: "bossuser"})
        |> render_submit()

      assert {:error, {:redirect, %{to: "/auth/verify/" <> _}}} = result
      assert Accounts.get_by_username("bossuser").role == "superadmin"
    end

    test "an unchecked attestation ends the signup rather than limiting it", %{conn: conn} do
      user_fixture()
      before = Accounts.count()
      {:ok, view, _html} = live(conn, ~p"/signup")

      view |> element("[phx-click=toggle][phx-value-field=consent]") |> render_click()

      html =
        view
        |> form("form[phx-submit=register]", %{email: "x@x.io", username: "xuser"})
        |> render_submit()

      assert html =~ "Polyphony is for adults"
      assert html =~ "we&#39;d rather say no than do it badly"
      # No retry button and no way back to the form on this screen.
      refute html =~ "Make my account"

      # Refusing someone must not create a row about them.
      assert Accounts.count() == before
      assert Accounts.get_by_email("x@x.io") == nil
    end

    test "the invite survives a refusal, so nobody has to ask for a replacement", %{conn: conn} do
      _ = Polyphony.Accounts.Roles.roles()
      admin = user_fixture(%{role: "superadmin"})
      {:ok, invite} = Accounts.create_invite(admin)

      {:ok, view, _html} = live(conn, ~p"/signup")
      view |> element("[phx-click=toggle][phx-value-field=consent]") |> render_click()

      view
      |> form("form[phx-submit=register]", %{
        email: "x@x.io",
        username: "xuser",
        invite_token: invite.token
      })
      |> render_submit()

      assert Accounts.open_invite(invite.token) != nil
    end

    test "a used invite says so at the field it belongs to", %{conn: conn} do
      user_fixture()
      {:ok, view, _html} = live(conn, ~p"/signup")

      view |> element("[phx-click=toggle][phx-value-field=attest]") |> render_click()
      view |> element("[phx-click=toggle][phx-value-field=consent]") |> render_click()

      html =
        view
        |> form("form[phx-submit=register]", %{
          email: "x@x.io",
          username: "xuser",
          invite_token: "nope"
        })
        |> render_submit()

      assert html =~ "Invites work once"
    end

    test "a taken name says the one thing worth saying about it", %{conn: conn} do
      user_fixture()
      _ = Polyphony.Accounts.Roles.roles()
      admin = user_fixture(%{role: "superadmin", username: "theboss"})
      {:ok, invite} = Accounts.create_invite(admin)

      {:ok, view, _html} = live(conn, ~p"/signup")
      view |> element("[phx-click=toggle][phx-value-field=attest]") |> render_click()
      view |> element("[phx-click=toggle][phx-value-field=consent]") |> render_click()

      html =
        view
        |> form("form[phx-submit=register]", %{
          email: "new@x.io",
          username: "theboss",
          invite_token: invite.token
        })
        |> render_submit()

      assert html =~ "Taken. Try something else."
    end
  end

  describe "signing in" do
    test "check-your-email is the whole experience, with both escape routes", %{conn: conn} do
      user = user_fixture(%{email: "known@x.io"})
      {:ok, view, _html} = live(conn, ~p"/login")

      html = view |> form("form[phx-submit=send]", %{email: user.email}) |> render_submit()

      assert html =~ "Have a look in your inbox"
      assert html =~ "known@x.io"
      assert html =~ "It works once and lasts fifteen minutes."
      assert html =~ "Send it again"
      assert html =~ "Use a different address"
      # And the spam line, before anybody needs it.
      assert html =~ "worth checking spam"
      assert html =~ "click to sign in"
    end

    test "an unknown address gets the identical screen, revealing nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login")

      html = view |> form("form[phx-submit=send]", %{email: "nobody@x.io"}) |> render_submit()

      assert html =~ "Have a look in your inbox"
      assert html =~ "nobody@x.io"
      # The one difference is a dev convenience, never a signal to a visitor.
      refute html =~ "click to sign in"
    end

    test "a different address takes you back to the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/login")
      view |> form("form[phx-submit=send]", %{email: "typo@x.io"}) |> render_submit()

      html = view |> element("[phx-click=different]") |> render_click()

      assert html =~ "Send me a link"
      refute html =~ "Have a look in your inbox"
    end
  end

  describe "coming back" do
    test "signing in cancels a pending deletion, which is what makes the promise true" do
      user = user_fixture()
      {:ok, user} = Accounts.request_deletion(user)
      assert user.deletion_requested_at != nil

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> PolyphonyWeb.Auth.log_in_user(user)

      assert Accounts.get(user.id).deletion_requested_at == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "isn't being deleted any more"
    end
  end

  test "an authed area redirects a signed-out visitor to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/library")
  end
end
