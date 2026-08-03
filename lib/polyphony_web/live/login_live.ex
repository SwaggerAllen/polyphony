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

  alias Polyphony.Accounts
  alias PolyphonyWeb.{Auth, Kit}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Sign in", sent_to: nil, dev_link: nil)}
  end

  def handle_event("send", %{"email" => email}, socket) do
    safe(socket, fn ->
      link =
        case Accounts.get_by_email(email) do
          nil -> nil
          user -> dev_link(Auth.deliver_magic_link(user))
        end

      {:noreply, assign(socket, sent_to: String.trim(to_string(email)), dev_link: link)}
    end)
  end

  def handle_event("again", _params, socket) do
    safe(socket, fn ->
      case Accounts.get_by_email(socket.assigns.sent_to) do
        nil ->
          {:noreply, put_flash(socket, :info, "Sent again.")}

        user ->
          {:noreply,
           socket
           |> assign(dev_link: dev_link(Auth.deliver_magic_link(user)))
           |> put_flash(:info, "Sent again.")}
      end
    end)
  end

  def handle_event("different", _params, socket),
    do: {:noreply, assign(socket, sent_to: nil, dev_link: nil)}

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
    <Kit.frame class="flex flex-col min-h-[100dvh] items-center justify-center p-4">
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
      <div class="ttl text-[22px] font-semibold mb-1">Polyphony</div>
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
