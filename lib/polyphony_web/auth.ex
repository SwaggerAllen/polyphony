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

  require Logger

  alias Polyphony.{Accounts, Notifications}
  alias Polyphony.Accounts.Roles
  alias Phoenix.LiveView

  @salt "magic link"
  @max_age 60 * 15

  # Same flag the login screen's on-page link uses, read the same fail-closed way:
  # only an explicit `true` outside prod lets a usable link reach a log or a page.
  @expose_magic_link Application.compile_env(:polyphony, :expose_magic_link, false) == true

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
    token = sign_token(user.id)
    url = url(~p"/auth/verify/#{token}")

    # Logged so the trail reaches the debug drawer: on a phone, with no console, the
    # question is always "was a link even generated, and did the mail go anywhere?".
    # `Notifications.dispatch/6` logs the delivery outcome and which transport ran;
    # this line is the request side of the same story.
    #
    # The token is **fingerprinted, not printed**. The drawer renders for anyone who
    # can load a page while `DEBUG_DRAWER` is on — it is not admin-gated, and it can't
    # be, because its most valuable use is diagnosing sign-in while signed out. A live
    # 15-minute session token in that stream is the same account-takeover hole the
    # login screen's on-page link was. Eight characters is plenty to match the link
    # you received against the one that was sent, and useless for signing in.
    Logger.info("[mail] magic_link requested for user ##{user.id} · token #{fingerprint(token)}")

    log_url(url)

    Notifications.deliver(user, :magic_link, %{url: url}, force: true)
    url
  end

  # Branched at compile time, as `LoginLive` does with the same flag: a prod build
  # contains no clause that can put a usable link in a log.
  if @expose_magic_link do
    defp log_url(url), do: Logger.info("[mail] magic_link url #{url}")
  else
    defp log_url(_url), do: :ok
  end

  # Shared with the crash reporter, which needs the identical rule for the identical
  # reason — and which is where the note lives about why this cannot measure from the
  # front of a `Phoenix.Token`. It used to, and printed the same eight characters for
  # every magic link the app had ever sent.
  defp fingerprint(token), do: Polyphony.Redact.fingerprint(token)

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
    |> remember(user)
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

  @doc """
  Log out: drop the session, and forget the device.

  Forgetting is the difference between *signed out* and *expired*. The remember cookie
  exists because the session ends on its own — it now carries a 30-day `max_age`
  (`PolyphonyWeb.Endpoint`), and before that it died with the browser, which on a phone
  is whenever the OS feels like it. Either way it runs out, and coming back to a form
  you have to retype is the entire complaint. But "sign me out" is a deliberate act, and
  leaving the address behind for the next person to see would answer a question nobody
  asked.
  """
  def log_out_user(conn) do
    conn
    |> renew_session()
    |> forget()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  end

  # ── Remember this device (§B2) ──────────────────────────────────────────────────

  # Deliberately **not** a credential. It holds a user id and nothing else, and the
  # only thing it can do is put a *Send me a link* button on screen — the link still
  # goes to the inbox, which is the one thing a stolen device doesn't come with. That
  # is the whole reason this outlives the session rather than matching it: the worst it
  # grants is the ability to send its owner an email.
  #
  # It must stay **longer** than the session's 30 days (`PolyphonyWeb.Endpoint`). If the
  # two ever meet, an expiring session lands on the sign-in form instead of `/resume`,
  # and this cookie stops doing the one job it has.
  @remember_cookie "_polyphony_remember"
  @remember_max_age 60 * 60 * 24 * 60

  @doc "Remember this device, so an expired session lands on `/resume` and not a form."
  @spec remember(Plug.Conn.t(), Accounts.User.t()) :: Plug.Conn.t()
  def remember(conn, user) do
    put_resp_cookie(conn, @remember_cookie, user.id,
      # Encrypted rather than signed: signing only stops tampering, and the value
      # would still be readable by anything that can see the cookie. There is no
      # reason for it to be legible at all.
      encrypt: true,
      max_age: @remember_max_age,
      http_only: true,
      same_site: "Lax",
      # Automatic, so dev over http still works and prod is never sent in the clear.
      secure: conn.scheme == :https
    )
  end

  @doc "Forget this device."
  @spec forget(Plug.Conn.t()) :: Plug.Conn.t()
  def forget(conn), do: delete_resp_cookie(conn, @remember_cookie)

  @doc """
  The `live_session :session` MFA: lifts the remember cookie into the LiveView session.

  It has to come this way round. `on_mount` hooks are handed the session, not the
  conn, and cookies are not in `connect_info` — so a hook has no way to read one. This
  runs on the dead render, where the conn still exists, and the result is merged into
  the session both mounts see.
  """
  @spec remembered_session(Plug.Conn.t()) :: %{optional(String.t()) => term()}
  def remembered_session(conn) do
    case fetch_cookies(conn, encrypted: [@remember_cookie]).cookies[@remember_cookie] do
      nil -> %{}
      user_id -> %{"remembered_user_id" => user_id}
    end
  end

  @doc """
  The remembered `%User{}`, or nil.

  Loaded through the same `load_user/1` as a live session, so a suspended or deleted
  account is not remembered either — the cookie outlives both, and a device that keeps
  offering to sign you into an account that no longer exists is worse than one that
  forgets.
  """
  @spec remembered_user(map()) :: Accounts.User.t() | nil
  def remembered_user(session), do: load_user(session["remembered_user_id"])

  # ── on_mount (LiveViews) ─────────────────────────────────────────────────────────

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  def on_mount(:require_authed, _params, session, socket) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, send_to_sign_in(socket, session)}
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

  # A device that has signed in before goes to the one-button resume screen rather than
  # the form — the *page* is what differs, so it is a redirect and not a flash. No
  # flash on that branch either: `/resume` says why you are there, and hearing it twice
  # reads as two separate things having gone wrong.
  #
  # The id is passed through unverified. Checking it here would put a query on the
  # signed-out path of every gated page; `/resume` loads it once and falls back to the
  # form when there is no account behind it, which keeps one place responsible.
  defp send_to_sign_in(socket, %{"remembered_user_id" => id}) when not is_nil(id),
    do: LiveView.redirect(socket, to: ~p"/resume")

  defp send_to_sign_in(socket, _session) do
    socket
    |> LiveView.put_flash(:error, "Please sign in.")
    |> LiveView.redirect(to: ~p"/login")
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
