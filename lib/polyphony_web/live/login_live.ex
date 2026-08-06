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
  alias PolyphonyWeb.{Auth, Kit, Layouts}

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
    <Kit.frame class="relative flex flex-col min-h-[100dvh] items-center justify-center p-4">
      <Layouts.corner_menu current_user={@current_user} />
      <Kit.sheet class="w-full max-w-sm">
        <.sent :if={@sent_to} {assigns} />
        <.form_state :if={is_nil(@sent_to)} {assigns} />
      </Kit.sheet>
    </Kit.frame>
    """
  end

  defp form_state(assigns) do
    ~H"""
    <div class="px-5 py-6 text-center row">
      <%!-- The wordmark is the way back to the landing page, which is the convention
            every site has and the only route out of here for someone who arrived on a
            bookmark or a link and wants to know what they're signing into. --%>
      <.link navigate={~p"/"} class="ttl text-[22px] font-semibold mb-1 block">Polyphony</.link>
      <p class="text-[13px] leading-relaxed dim">
        Write a world, cast some people, and find out what they do.
      </p>
    </div>

    <div class="px-5 py-5">
      <form id="login-form" phx-submit="send">
        <label for="email" class="lbl dim mb-1.5 block">Email</label>
        <input
          type="email"
          name="email"
          id="email"
          required
          autofocus
          placeholder="you@example.com"
          class="field px-3 py-2.5 text-[14px] w-full mb-3"
        />
        <Kit.btn kind={:primary} type="submit" class="w-full justify-center mb-3">
          Send me a link
        </Kit.btn>
      </form>
      <p class="text-[12px] leading-relaxed dim text-center">
        No password to remember. We'll email you a link that signs you in.
      </p>
    </div>

    <%!-- Its own field and its own submit, so the address above keeps `type="email"`
          and the browser's validation with it. Secondary by placement, because an
          address is what almost everyone will reach for. --%>
    <div class="px-5 py-4 row" style="background:var(--b2)">
      <form id="login-username-form" phx-submit="send_username">
        <label for="username" class="lbl dim mb-1.5 block">Or your username</label>
        <div class="flex gap-1.5">
          <input
            type="text"
            name="username"
            id="username"
            required
            placeholder="yourhandle"
            autocapitalize="none"
            autocorrect="off"
            spellcheck="false"
            class="field px-3 py-2.5 text-[14px] flex-1 mono"
          />
          <Kit.btn kind={:ghost} type="submit">Send</Kit.btn>
        </div>
        <p class="text-[11.5px] leading-relaxed dim mt-2">
          The link still goes to the email on that account.
        </p>
      </form>
    </div>

    <div class="px-5 py-3 row" style="background:var(--b2)">
      <p class="text-[12.5px] text-center dim">
        Got an invite? <.link navigate={~p"/signup"} style="color:var(--bc)">Use it here</.link>
      </p>
    </div>
    """
  end

  # The cost of no passwords is that this screen is the whole experience: both escape
  # routes, and the spam line before it's needed.
  defp sent(assigns) do
    ~H"""
    <div class="px-5 py-8 text-center">
      <div class="ttl text-[19px] font-semibold mb-2">Have a look in your inbox</div>
      <p class="text-[13.5px] leading-relaxed mb-1">
        We've sent a link to <b><%= @sent_to %></b>.
      </p>
      <p class="text-[13px] leading-relaxed dim mb-5">It works once and lasts fifteen minutes.</p>

      <div class="flex flex-col gap-1.5">
        <Kit.btn type="button" phx-click="again" class="justify-center">Send it again</Kit.btn>
        <Kit.btn type="button" phx-click="different" class="justify-center">
          Use a different address
        </Kit.btn>
      </div>

      <p :if={@dev_link} class="text-[11.5px] mt-4">
        <a href={@dev_link} class="underline">Dev: click to sign in</a>
      </p>

      <p class="text-[11.5px] leading-relaxed dim mt-4">
        Nothing there? It's worth checking spam — and worth checking you typed it right.
      </p>
    </div>
    """
  end
end
