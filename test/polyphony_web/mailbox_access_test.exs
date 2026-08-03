defmodule PolyphonyWeb.MailboxAccessTest do
  @moduledoc """
  Who can read the sent-mail viewer.

  This is the most dangerous page the app can serve. It renders **every message this
  node has sent**, magic links included — so anyone who reaches it can sign in as any
  account that has requested one. That is strictly worse than the debug drawer, which
  only ever shows an eight-character fingerprint.

  It is deliberately *not* behind `require_admin`. The moment you need to read a
  sign-in link is the moment you are not signed in, so an admin gate would lock the
  door with the key inside. Basic auth is the compromise: it works while signed out,
  it is not guessable, and it has to be switched on.
  """
  use PolyphonyWeb.ConnCase, async: false

  @creds [username: "operator", password: "correct-horse"]

  defp with_config(config, fun) do
    previous = Enum.map(config, fn {k, _} -> {k, Application.get_env(:polyphony, k)} end)
    Enum.each(config, fn {k, v} -> Application.put_env(:polyphony, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> Application.delete_env(:polyphony, k)
        {k, v} -> Application.put_env(:polyphony, k, v)
      end)
    end
  end

  defp auth_header(conn, user, pass),
    do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth(user, pass))

  describe "unarmed" do
    test "404s, and does not advertise that the viewer exists", %{conn: conn} do
      with_config([dev_mailbox: false, mailbox_auth: nil], fn ->
        conn = get(conn, "/dev/mailbox")

        # 404 rather than 401 on purpose: a 401 tells a stranger there is something
        # here worth guessing a password for.
        assert conn.status == 404
        refute get_resp_header(conn, "www-authenticate") != []
      end)
    end
  end

  describe "armed with basic auth" do
    test "no credentials is a challenge, not the mailbox", %{conn: conn} do
      with_config([dev_mailbox: false, mailbox_auth: @creds], fn ->
        conn = get(conn, "/dev/mailbox")

        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") != []
      end)
    end

    test "wrong credentials get nowhere", %{conn: conn} do
      with_config([dev_mailbox: false, mailbox_auth: @creds], fn ->
        conn = conn |> auth_header("operator", "hunter2") |> get("/dev/mailbox")

        assert conn.status == 401
      end)
    end

    test "the right credentials get in — while signed out, which is the point", %{conn: conn} do
      with_config([dev_mailbox: false, mailbox_auth: @creds], fn ->
        # No session, no user. If this needed a login it would be useless for the one
        # job it has.
        conn = conn |> auth_header("operator", "correct-horse") |> get("/dev/mailbox")

        assert conn.status == 200
      end)
    end
  end

  describe "in dev" do
    test "open, with no credentials to remember", %{conn: conn} do
      with_config([dev_mailbox: true, mailbox_auth: nil], fn ->
        assert get(conn, "/dev/mailbox").status == 200
      end)
    end
  end
end
