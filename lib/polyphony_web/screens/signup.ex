defmodule PolyphonyWeb.Screens.Signup do
  @moduledoc """
  Sign up, as markup.

  Invite-only, and the consent boxes are **real checkbox inputs with labels**, not styled
  divs — a consent you cannot reach with a keyboard is not a consent. The username rule
  is stated before anybody can break it, because a rule you only learn by failing is a
  rule the form kept to itself.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Accounts.User
  alias PolyphonyWeb.{Kit, Layouts}

  attr(:turned_away, :boolean,
    default: false,
    doc: "an unchecked attestation ends the signup — and creates no row about the person refused"
  )

  attr(:first?, :boolean,
    default: false,
    doc: "the very first account on a fresh install skips the invite"
  )

  attr(:field, :atom,
    default: nil,
    doc: "which field the error belongs to, or nil for a form-level one"
  )

  attr(:error, :string, default: nil)
  attr(:attest, :boolean, default: false)
  attr(:consent, :boolean, default: false)
  attr(:current_user, :map, default: nil)

  def screen(%{turned_away: true} = assigns) do
    ~H"""
    <Kit.frame class="relative flex flex-col min-h-[100dvh] items-center justify-center p-4">
      <Layouts.corner_menu current_user={@current_user} />
      <Kit.sheet class="w-full max-w-sm">
        <%!-- No retry button and no "go back and change your answer". A door that
              reopens on the same screen isn't a door. --%>
        <div class="px-5 py-9 text-center">
          <div class="ttl text-[19px] font-semibold mb-2">Polyphony is for adults</div>
          <p class="text-[13.5px] leading-relaxed mb-1">
            We can't offer accounts to people under 18.
          </p>
          <p class="text-[13px] leading-relaxed dim">
            One day we'd like to, properly — with the safeguards that would need. That's a
            long way off, and we'd rather say no than do it badly.
          </p>
        </div>
      </Kit.sheet>
    </Kit.frame>
    """
  end

  def screen(assigns) do
    ~H"""
    <Kit.frame class="relative flex flex-col min-h-[100dvh] items-center justify-center p-4">
      <Layouts.corner_menu current_user={@current_user} />
      <Kit.sheet class="w-full max-w-sm">
        <Kit.row class="px-5 py-4" style="background:var(--b2)">
          <%!-- Same wordmark-goes-home convention as the sign-in screen. Somebody
                handed an invite code has more reason than anyone to want to read what
                they're joining before they fill this in. --%>
          <.link navigate={~p"/"} class="lbl dim mb-1 block">Polyphony</.link>
          <div class="ttl text-[17px] font-semibold">Make an account</div>
          <p :if={@first?} class="text-[11px] leading-relaxed dim mt-1">
            You're the first — this account runs the place.
          </p>
        </Kit.row>

        <form id="signup-form" phx-submit="register">
          <Kit.row :if={not @first?} class="px-5 py-4">
            <label for="invite_token" class="lbl dim mb-1.5 block">Invite code</label>
            <input
              type="text"
              name="invite_token"
              id="invite_token"
              class="field px-3 py-2.5 mono text-[13px] w-full"
              style={@field == :invite && "border-color:var(--pencil)"}
            />
            <.field_error :if={@field == :invite} message={@error} />
            <p :if={@field != :invite} class="text-[11px] leading-relaxed dim mt-1.5">
              Polyphony is invite-only while it's young.
            </p>
          </Kit.row>

          <Kit.row class="px-5 py-4">
            <label for="email" class="lbl dim mb-1.5 block">Email</label>
            <input
              type="email"
              name="email"
              id="email"
              required
              placeholder="you@example.com"
              class="field px-3 py-2.5 text-[14px] w-full"
              style={@field == :email && "border-color:var(--pencil)"}
            />
            <.field_error :if={@field == :email} message={@error} />
          </Kit.row>

          <Kit.row class="px-5 py-4">
            <label for="username" class="lbl dim mb-1.5 block">What should we call you</label>
            <input
              type="text"
              name="username"
              id="username"
              required
              minlength="3"
              maxlength="32"
              pattern={User.username_pattern()}
              title={User.username_rule()}
              placeholder="A name other people will see"
              aria-describedby="username-rule"
              class="field px-3 py-2.5 text-[14px] w-full"
              style={@field == :username && "border-color:var(--pencil)"}
            />
            <%!-- Before anything is typed, not after it is rejected. The rule was only
                  ever stated by the failure — and the failure said "Taken", which is
                  what a *format* error came back as too, so the one message you did get
                  was wrong about which rule you'd broken. --%>
            <p id="username-rule" class="text-[11px] leading-relaxed dim mt-1.5">
              <%= User.username_rule() %>
            </p>
            <.field_error :if={@field == :username} message={@error} />
          </Kit.row>

          <div class="px-5 py-4">
            <%!-- Real `<input type="checkbox">`es inside the form, not `phx-click` on a
                  span drawing a tick. The span was unreachable by keyboard, announced
                  as nothing by a screen reader, and needed a live socket to change —
                  on the two controls that decide whether an account can exist at all.
                  The kit's tick is now decoration over the input (`sr-only peer`, the
                  same pattern the turn editor uses), so it looks identical and *is* a
                  checkbox. The state rides the submit, which is also why the toggle
                  round-trip is gone. --%>
            <label class="flex items-start gap-2.5 mb-3 cursor-pointer">
              <input
                type="checkbox"
                name="attest"
                value="true"
                checked={@attest}
                aria-label="I'm 18 or over"
                class="sr-only peer"
              />
              <Kit.chk class="mt-0.5" />
              <div>
                <div class="text-[13px] leading-snug">I'm 18 or over</div>
                <div class="text-[11px] leading-relaxed dim mt-0.5">
                  Polyphony is for adults. We can't offer it to under-18s yet.
                </div>
              </div>
            </label>

            <label class="flex items-start gap-2.5 mb-4 cursor-pointer">
              <input
                type="checkbox"
                name="consent"
                value="true"
                checked={@consent}
                aria-label="I've read the terms and the privacy notice"
                class="sr-only peer"
              />
              <Kit.chk class="mt-0.5" />
              <div class="text-[13px] leading-snug">
                I've read the <span class="underline">terms</span> and the
                <span class="underline">privacy notice</span>
              </div>
            </label>

            <.field_error :if={is_nil(@field) and @error} message={@error} />

            <%!-- Deliberately not disabled: a dead button tells you nothing, and the
                  rejected-state copy at the field it belongs to does. --%>
            <Kit.btn kind={:primary} type="submit" class="w-full justify-center">
              Make my account
            </Kit.btn>
          </div>
        </form>

        <Kit.row class="px-5 py-3" style="background:var(--b2)">
          <p class="text-[12.5px] text-center dim">
            Already have one? <.link navigate={~p"/login"} style="color:var(--bc)">Sign in</.link>
          </p>
        </Kit.row>
      </Kit.sheet>
    </Kit.frame>
    """
  end

  # "Taken" was the answer to every username error, including the two that are about the
  # rule rather than about somebody else having it — so the one time you were told
  # anything, you were told the wrong thing and the name you tried was fine.
  def username_message({_msg, opts}) do
    if opts[:constraint] == :unique,
      do: "Taken. Try something else.",
      else: User.username_rule()
  end

  def username_message(_), do: User.username_rule()

  attr(:message, :string, required: true)

  defp field_error(assigns) do
    ~H"""
    <div class="flex items-start gap-1.5 mt-1.5">
      <Kit.dot colour="var(--pencil)" class="mt-1.5 shrink-0" />
      <span class="text-[12px] leading-relaxed" style="color:var(--pencil)"><%= @message %></span>
    </div>
    """
  end
end
