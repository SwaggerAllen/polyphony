defmodule PolyphonyWeb.ResumeLiveTest do
  @moduledoc """
  Remember-me: the device knows who you are, and can offer to email you — nothing more.

  The distinction this file exists to hold is that the cookie is **not a credential**.
  It carries a user id and buys exactly one thing: a *Send me a link* button instead of
  a form. The link still goes to the inbox, which is the one thing a stolen phone
  doesn't come with. If that ever stops being true — if the cookie starts signing
  anyone in — a year-long, `Lax`, always-present cookie becomes an account takeover.

  The rest is the correction paths. A screen that assumes who you are has to be trivial
  to correct, and one of those corrections deletes a cookie, which nothing over the
  LiveView socket can do.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Notifications, Repo}
  alias PolyphonyWeb.Auth

  @cookie "_polyphony_remember"

  # Signs in the way the app does — through the controller — so the cookie under test
  # is the one the real path sets, not one the test made up.
  defp signed_in_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> get(~p"/auth/verify/#{Auth.sign_token(user.id)}")
  end

  defp remembering_conn(user) do
    conn = signed_in_conn(user)

    # Carry the response cookie onto a fresh conn *without* the session: that is the
    # state this whole feature is about — the session cookie has no max_age, so it dies
    # with the browser while the remember cookie doesn't.
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Test.put_req_cookie(@cookie, conn.resp_cookies[@cookie].value)
  end

  describe "the cookie" do
    test "signing in sets it, encrypted rather than merely signed" do
      user = user_fixture()
      value = signed_in_conn(user).resp_cookies[@cookie].value

      base =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.put_req_cookie(@cookie, value)
        |> Map.put(:secret_key_base, PolyphonyWeb.Endpoint.config(:secret_key_base))

      # A *signed* cookie is tamper-proof and perfectly legible — the payload is just
      # base64. Reading it back the signed way must fail, and the encrypted way must
      # round-trip, or "encrypted" is a comment rather than a fact.
      refute Plug.Conn.fetch_cookies(base, signed: [@cookie]).cookies[@cookie]
      assert Plug.Conn.fetch_cookies(base, encrypted: [@cookie]).cookies[@cookie] == user.id
    end

    test "it is http-only and long-lived, and the session cookie is neither" do
      cookie = signed_in_conn(user_fixture()).resp_cookies[@cookie]

      # http_only keeps it away from any script that gets onto the page.
      assert cookie.http_only
      assert cookie.same_site == "Lax"
      # Long on purpose — outliving the session is the entire feature.
      assert cookie.max_age > 60 * 60 * 24 * 30
    end

    test "signing out forgets the device" do
      user = user_fixture()
      conn = user |> signed_in_conn() |> recycle() |> log_in_user(user) |> get(~p"/logout")

      # Deleted, not merely unset: signing out is deliberate, and leaving the address
      # for the next person answers a question nobody asked.
      assert conn.resp_cookies[@cookie].max_age == 0
    end
  end

  describe "an expired session on a remembered device" do
    test "lands on the resume screen instead of the form" do
      user = user_fixture()

      assert {:error, {:redirect, %{to: "/resume"}}} =
               live(remembering_conn(user), ~p"/library")
    end

    test "and a device that has never signed in still gets the form" do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/library")

      assert to == "/login"
      assert flash["error"] =~ "sign in"
    end

    test "a live session outranks the cookie, rather than the other way round" do
      user = user_fixture()

      # Both present at once — the case that matters. A remembered device whose session
      # is *fine* must not be bounced to a screen offering to email them a link.
      conn = user |> remembering_conn() |> log_in_user(user)

      {:ok, _view, _html} = live(conn, ~p"/library")
    end
  end

  describe "the resume screen" do
    setup do
      user = user_fixture(%{email: "wren@example.com", username: "wren"})
      %{user: user, conn: remembering_conn(user)}
    end

    test "greets by handle and shows a masked address", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resume")

      assert html =~ "Welcome back"
      assert html =~ "@wren"
      # The handle is the public identity by design; the address is the auth-only half
      # and whoever holds the phone is only *probably* its owner.
      assert html =~ "w***@example.com"
      refute html =~ "wren@example.com"
    end

    test "one button sends the link, and says so", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/resume")

      html = view |> element("button[phx-click=send]") |> render_click()

      assert html =~ "Have a look in your inbox"
      assert [%{type: "magic_link", status: "sent"}] = Notifications.history(user.id)
    end

    test "and can send it again", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/resume")
      view |> element("button[phx-click=send]") |> render_click()
      view |> element("button[phx-click=again]") |> render_click()

      assert length(Notifications.history(user.id)) == 2
    end

    test "the address is never printed whole, sent state included", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/resume")
      html = view |> element("button[phx-click=send]") |> render_click()

      refute html =~ "wren@example.com"
      assert html =~ "w***@example.com"
    end

    test "offers all three corrections", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/resume")

      # A different account, a new account, and "this is not my device".
      assert html =~ ~s|href="/login"|
      assert html =~ ~s|href="/signup"|
      assert html =~ ~s|href="/auth/forget"|
    end
  end

  describe "when there is nothing to resume" do
    test "no cookie at all is the form" do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/resume")
    end

    test "a cookie for an account that has gone is the form" do
      user = user_fixture()
      conn = remembering_conn(user)
      Repo.delete!(user)

      # The cookie outlives the account, and a device that keeps offering to sign you
      # into something that no longer exists is worse than one that forgets.
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/resume")
    end

    test "a suspended account is not remembered either" do
      user = user_fixture()
      conn = remembering_conn(user)

      user
      |> Ecto.Changeset.change(
        suspended_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond),
        suspended_until:
          NaiveDateTime.utc_now()
          |> NaiveDateTime.add(3600)
          |> NaiveDateTime.truncate(:microsecond)
      )
      |> Repo.update!()

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/resume")
    end
  end

  describe "forgetting" do
    test "deletes the cookie and returns you to the form" do
      user = user_fixture()
      conn = user |> remembering_conn() |> get(~p"/auth/forget")

      assert redirected_to(conn) == "/login"
      assert conn.resp_cookies[@cookie].max_age == 0
    end

    test "a cookie that decrypts to nothing is the form, not a crash" do
      # Deletion emits a `Set-Cookie` with an empty value and `max_age=0`; garbage
      # arrives from anyone who edits their own cookies. Neither may reach the page as
      # anything other than "not remembered" — a 500 on the signed-out path of every
      # gated route is a denial of service you inflict on yourself.
      for value <- ["", "not-a-cookie", "SFMyNTY.bogus.bogus"] do
        conn = Phoenix.ConnTest.build_conn() |> Plug.Test.put_req_cookie(@cookie, value)

        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/library"),
               "#{inspect(value)} was not treated as unremembered"
      end
    end
  end
end
