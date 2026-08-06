defmodule PolyphonyWeb.Screens.Resume do
  @moduledoc """
  Resume on a remembered device, as markup.

  Only reachable with the remember cookie, so it knows who you are before you have
  signed in — which is why the address is shown **redacted**. A screen that prints a
  whole email address is a screen that hands it to whoever picked up the laptop.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Notifications.Transport
  alias PolyphonyWeb.{Kit, Layouts}

  attr(:user, :map,
    required: true,
    doc: "the remembered account — only its redacted address is shown"
  )

  attr(:sent, :boolean, default: false)
  attr(:dev_link, :string, default: nil, doc: "dev only; never set in prod")
  attr(:current_user, :map, default: nil)

  def screen(assigns) do
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
