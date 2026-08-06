defmodule PolyphonyWeb.Screens.Login do
  @moduledoc """
  Sign in, as markup — ported from `ux/polyphony-settings-auth.html` §03.

  **Magic link only.** No passwords to store, reset, or leak. The cost is a longer
  first-time flow, which means *check your email* isn't a placeholder — it is the whole
  experience, and it gets both escape routes and the spam line before anyone needs it.

  Whether an address has an account is never revealed: the sent state is identical
  either way, because an enumeration oracle on the login screen is a worse trade than
  a moment of ambiguity for someone who mistyped. **That is a property of this markup**,
  not of the LiveView — which is the reason it is worth being able to render both states
  side by side in `/storybook` and look at them.

  See `PolyphonyWeb.Screens` for why the markup lives apart from the LiveView.
  """
  use PolyphonyWeb, :html

  alias PolyphonyWeb.{Kit, Layouts}

  # "" -> "email"; "sent" -> "sent-email". The app renders this screen once and its ids
  # are what tests target; storybook renders every variation on one page and must not
  # let one variation's label point at another's input.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")

  attr(:current_user, :map,
    default: nil,
    doc: "signed-in user, or nil — only reaches the corner menu"
  )

  attr(:sent_to, :string,
    default: nil,
    doc: "the address a link just went to; nil is the form, set is the confirmation"
  )

  attr(:dev_link, :string,
    default: nil,
    doc: "a clickable magic link, dev only (`:expose_magic_link`). Never set in prod."
  )

  def screen(assigns) do
    ~H"""
    <Kit.frame class="relative flex flex-col min-h-[100dvh] items-center justify-center p-4">
      <Layouts.corner_menu current_user={@current_user} />
      <Kit.sheet class="w-full max-w-sm">
        <.sent :if={@sent_to} sent_to={@sent_to} dev_link={@dev_link} />
        <.form_state :if={is_nil(@sent_to)} id={@id} />
      </Kit.sheet>
    </Kit.frame>
    """
  end

  attr(:id, :string, default: "")

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
      <form id={eid(@id, "login-form")} phx-submit="send">
        <label for={eid(@id, "email")} class="lbl dim mb-1.5 block">Email</label>
        <input
          type="email"
          name="email"
          id={eid(@id, "email")}
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
      <form id={eid(@id, "login-username-form")} phx-submit="send_username">
        <label for={eid(@id, "username")} class="lbl dim mb-1.5 block">Or your username</label>
        <div class="flex gap-1.5">
          <input
            type="text"
            name="username"
            id={eid(@id, "username")}
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
  attr(:sent_to, :string, required: true)
  attr(:dev_link, :string, default: nil)

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
