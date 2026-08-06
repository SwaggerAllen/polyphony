defmodule PolyphonyWeb.ResumeLive do
  @moduledoc """
  Coming back to a device that has been signed in before (§B2).

  The session cookie has no `max_age` — it dies with the browser, which on a phone is
  whenever the OS decides — so the common way to meet the sign-in screen is not "I have
  no account", it is "I had one ten minutes ago". Sending that person to a form is
  asking them to retype an address the server could have remembered, and the reward for
  typing it correctly is an email either way.

  So: one button. Everything else on the page is an escape route, because a screen that
  assumes it knows who you are has to be trivial to correct.

  Built from the same kit sheet as `LoginLive`, and its sent state is deliberately the
  same copy — it is the same event, and two phrasings for one thing would read as two
  different things having happened.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias Polyphony.Notifications.Transport
  alias PolyphonyWeb.{Auth, Kit, Layouts}

  def mount(_params, session, socket) do
    # No cookie, or a cookie for an account that has since gone: this page has nothing
    # to offer, and the form does.
    case Auth.remembered_user(session) do
      nil ->
        {:ok, redirect(socket, to: ~p"/login")}

      user ->
        {:ok, assign(socket, page_title: "Welcome back", user: user, sent: false, dev_link: nil)}
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, deliver(socket)}

  def handle_event("again", _params, socket),
    do: {:noreply, socket |> deliver() |> put_flash(:info, "Sent again.")}

  defp deliver(socket) do
    user = socket.assigns.user

    # The address is never logged whole: this line reaches the debug drawer, which is
    # not admin-gated. The handle is the public identity by design, so it carries the
    # "who" without carrying the auth-only half.
    Logger.info("[mail] resume requested for @#{user.username}")

    assign(socket, sent: true, dev_link: dev_link(Auth.deliver_magic_link(user)))
  end

  # Same fail-closed compile-time branch as `LoginLive`: outside prod the link is
  # surfaced so the flow works with no mailer, and a prod build contains no clause that
  # can return it.
  @expose_magic_link Application.compile_env(:polyphony, :expose_magic_link, false) == true

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
        <.sent :if={@sent} {assigns} />
        <.offer :if={not @sent} {assigns} />
        <.escapes />
      </Kit.sheet>
    </Kit.frame>
    """
  end

  defp offer(assigns) do
    ~H"""
    <div class="px-5 py-6 text-center row">
      <div class="ttl text-[22px] font-semibold mb-1">Welcome back</div>
      <p class="text-[13px] leading-relaxed dim">
        You've signed in on this device before, as
        <b class="mono">@<%= @user.username %></b>.
      </p>
    </div>

    <div class="px-5 py-5 text-center">
      <%!-- Masked, not printed. Whoever is holding the phone is probably its owner —
            but "probably" is doing work there, and the whole address is not needed to
            recognise your own. --%>
      <p class="text-[13px] leading-relaxed dim mb-3">
        We'll email a sign-in link to <b><%= Transport.redact(@user.email) %></b>.
      </p>
      <Kit.btn kind={:primary} type="button" phx-click="send" class="w-full justify-center">
        Send me a link
      </Kit.btn>
      <p class="text-[12px] leading-relaxed dim mt-3">
        Your session ended. Nothing else has — everything is where you left it.
      </p>
    </div>
    """
  end

  defp sent(assigns) do
    ~H"""
    <div class="px-5 py-8 text-center">
      <div class="ttl text-[19px] font-semibold mb-2">Have a look in your inbox</div>
      <p class="text-[13.5px] leading-relaxed mb-1">
        We've sent a link to <b><%= Transport.redact(@user.email) %></b>.
      </p>
      <p class="text-[13px] leading-relaxed dim mb-5">It works once and lasts fifteen minutes.</p>

      <Kit.btn type="button" phx-click="again" class="w-full justify-center">Send it again</Kit.btn>

      <p :if={@dev_link} class="text-[11.5px] mt-4">
        <a href={@dev_link} class="underline">Dev: click to sign in</a>
      </p>

      <p class="text-[11.5px] leading-relaxed dim mt-4">
        Nothing there? It's worth checking spam.
      </p>
    </div>
    """
  end

  # A page that assumes who you are needs the correction to be one tap away, and all
  # three corrections are different: a different account, a new account, and *this is
  # not my device*. Forgetting is an ordinary link rather than a `phx-click` because it
  # deletes a cookie, and nothing over the socket can.
  defp escapes(assigns) do
    ~H"""
    <div class="px-5 py-4 row" style="background:var(--b2)">
      <p class="text-[12.5px] text-center dim">
        <.link navigate={~p"/login"} style="color:var(--bc)">Use a different address</.link>
        · Got an invite? <.link navigate={~p"/signup"} style="color:var(--bc)">Use it here</.link>
      </p>
    </div>

    <div class="px-5 py-3 row" style="background:var(--b2)">
      <p class="text-[12px] text-center dim">
        Not you? <a href={~p"/auth/forget"} style="color:var(--bc)">Forget this device</a>
      </p>
    </div>
    """
  end
end
