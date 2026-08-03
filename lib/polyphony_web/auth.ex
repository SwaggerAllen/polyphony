defmodule PolyphonyWeb.Auth do
  @moduledoc """
  Session auth transport (§B2). The domain decides *who may do what* (`Accounts`);
  this is the login channel the backend deferred to the web layer.

  Login is **magic-link, no passwords**: a signed `Phoenix.Token` (15-min TTL) is
  delivered through the §B4 notification path. In dev the logging transport prints
  the link and `LoginLive` also surfaces it, so the whole flow works offline with no
  mailer. The session stores only the user id; `fetch_current_user/2` and the
  `on_mount` hooks load the `%User{}`.
  """
  use PolyphonyWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Polyphony.{Accounts, Notifications}
  alias Polyphony.Accounts.Roles
  alias Phoenix.LiveView

  @salt "magic link"
  @max_age 60 * 15

  # ── Token (magic link) ─────────────────────────────────────────────────────────

  @doc "A signed login token for `user` (15-min TTL)."
  def sign_token(user_id),
    do: Phoenix.Token.sign(PolyphonyWeb.Endpoint, @salt, user_id)

  @doc "Verify a login token, returning `{:ok, user_id}` or `{:error, reason}`."
  def verify_token(token),
    do: Phoenix.Token.verify(PolyphonyWeb.Endpoint, @salt, token, max_age: @max_age)

  @doc """
  Deliver a magic link to `user` via the notification path and return the URL (so
  dev can surface it). Sends a `:magic_link`-typed notification, `force:`d past prefs.
  """
  def deliver_magic_link(user) do
    url = url(~p"/auth/verify/#{sign_token(user.id)}")
    Notifications.deliver(user, :magic_link, %{url: url}, force: true)
    url
  end

  # ── Plug (dead views) ───────────────────────────────────────────────────────────

  @doc "Assign `:current_user` from the session (nil when signed out)."
  def fetch_current_user(conn, _opts) do
    user = conn |> get_session(:user_id) |> load_user()
    assign(conn, :current_user, user)
  end

  @doc """
  Log `user` in: store the id, renew the session, redirect home.

  Signing in **cancels a pending deletion**, which is what makes *sign back in within
  30 days and none of this happens* a promise rather than a hope. It's done here rather
  than on a settings screen because coming back is the act that means it.
  """
  def log_in_user(conn, user) do
    if Accounts.suspension_active?(user) do
      conn
      |> put_flash(:error, "This account is suspended.")
      |> redirect(to: ~p"/")
    else
      do_log_in(conn, user)
    end
  end

  defp do_log_in(conn, user) do
    {user, note} = un_delete(user)

    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> put_flash(:info, "Signed in as @#{user.username}.#{note}")
    |> redirect(to: ~p"/library")
  end

  defp un_delete(%{deletion_requested_at: nil} = user), do: {user, ""}

  defp un_delete(user) do
    case Accounts.cancel_deletion(user) do
      {:ok, restored} -> {restored, " Your account isn't being deleted any more."}
      _ -> {user, ""}
    end
  end

  @doc "Log out: drop the session."
  def log_out_user(conn) do
    conn
    |> renew_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  end

  # ── on_mount (LiveViews) ─────────────────────────────────────────────────────────

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  def on_mount(:require_authed, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> LiveView.put_flash(:error, "Please sign in.")
       |> LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = assign_current_user(socket, session)
    user = socket.assigns.current_user

    if user && Roles.admin?(role_atom(user.role)) do
      {:cont, socket}
    else
      {:halt,
       socket |> LiveView.put_flash(:error, "Admins only.") |> LiveView.redirect(to: ~p"/")}
    end
  end

  defp assign_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn -> load_user(session["user_id"]) end)
  end

  defp load_user(nil), do: nil

  # A suspended account is signed out on the next request rather than swept by a job:
  # the check is a read, so a lapsed suspension stops binding the moment it lapses and
  # a live one binds immediately, with no window either way.
  defp load_user(id) do
    case Accounts.get(id) do
      nil -> nil
      user -> unless Accounts.suspension_active?(user), do: user
    end
  end

  defp role_atom(role) when is_atom(role), do: role

  # Match the stored role string against the known role atoms. Using `Roles.roles/0`
  # (rather than `String.to_existing_atom/1`) both guarantees those atoms exist and
  # avoids a crash on an unrecognized value — an unknown role safely reads as the
  # least-privileged `:user`.
  defp role_atom(role) when is_binary(role),
    do: Enum.find(Roles.roles(), :user, &(Atom.to_string(&1) == role))
end
