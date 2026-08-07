defmodule PolyphonyWeb.LoginLive do
  @moduledoc """
  Sign in, ported from `ux/polyphony-settings-auth.html` §03.

  **Magic link only.** No passwords to store, reset, or leak. The cost is a longer
  first-time flow, which means *check your email* isn't a placeholder — it is the whole
  experience, and it gets both escape routes and the spam line before anyone needs it.

  Whether an address has an account is never revealed: the sent state is identical
  either way, because an enumeration oracle on the login screen is a worse trade than
  a moment of ambiguity for someone who mistyped.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias Polyphony.Accounts
  alias Polyphony.Notifications.Transport
  alias PolyphonyWeb.{Auth, Screens}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Sign in", sent_to: nil, dev_link: nil)}
  end

  def handle_event("send", %{"email" => email}, socket),
    do: safe(socket, fn -> {:noreply, deliver(socket, email)} end)

  # A second, separate field rather than one that takes either: keeping `type="email"`
  # on the address means the browser's own validation still catches a typo'd domain
  # before it becomes a silent no-match, and that is the common case by far.
  def handle_event("send_username", %{"username" => username}, socket),
    do: safe(socket, fn -> {:noreply, deliver(socket, username)} end)

  def handle_event("again", _params, socket) do
    safe(socket, fn ->
      socket = deliver(socket, socket.assigns.sent_to)
      {:noreply, put_flash(socket, :info, "Sent again.")}
    end)
  end

  def handle_event("different", _params, socket),
    do: {:noreply, assign(socket, sent_to: nil, dev_link: nil)}

  # The screen deliberately says the same thing either way, so **the log is the only
  # place the difference exists** — and without this line a sign-in that matched no
  # account produced no output at all, which is indistinguishable from the form never
  # having been submitted.
  #
  # It does mean an address can be tested for existence by anyone who can read the
  # drawer, which is why `DEBUG_DRAWER` belongs off once you are in. The screen itself
  # still reveals nothing.
  # One path for both fields and the resend, so a link can never be sent by one route
  # and not another.
  defp deliver(socket, identifier) do
    user = Accounts.get_by_login(identifier)
    log_attempt(identifier, user)

    socket
    |> assign(sent_to: String.trim(to_string(identifier)))
    |> assign(dev_link: user && dev_link(Auth.deliver_magic_link(user)))
  end

  defp log_attempt(identifier, user) do
    outcome = if user, do: "matched @#{user.username}", else: "no account"
    Logger.info("[mail] sign-in requested for #{shown(identifier)} — #{outcome}")
  end

  # An address is masked; a handle is not. The username is the *public* identity by
  # design (§B2) — the email is the one that is auth-only, and the drawer these lines
  # reach is readable by anyone while `DEBUG_DRAWER` is on.
  defp shown(identifier) do
    identifier = to_string(identifier)
    if String.contains?(identifier, "@"), do: Transport.redact(identifier), else: identifier
  end

  # Outside prod the link is surfaced so the flow works with no mailer; in prod it only
  # ever goes to email. Defaulting to `false` is the whole point — an absent or
  # misspelled config must hide the link, never print it.
  @expose_magic_link Application.compile_env(:polyphony, :expose_magic_link, false) == true

  # Branched at compile time rather than runtime, so a prod build contains no clause
  # that can return the URL at all — there is nothing left to accidentally reach.
  if @expose_magic_link do
    defp dev_link(url), do: url
  else
    defp dev_link(_url), do: nil
  end

  def render(assigns) do
    ~H"""
    <Screens.Login.screen
      current_user={@current_user}
      sent_to={@sent_to}
      dev_link={@dev_link}
    />
    """
  end
end
