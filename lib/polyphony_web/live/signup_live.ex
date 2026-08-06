defmodule PolyphonyWeb.SignupLive do
  @moduledoc """
  Sign up, ported from `ux/polyphony-settings-auth.html` §03.

  Three gates, and each one has to be honest about why it's there.

  ## 18+ is eligibility, not a content setting

  Under-18s can't use Polyphony at all — supporting them would mean parental controls
  and in-house filtering, which is a large piece of work deferred a long way out. So an
  unchecked box **ends** the signup rather than limiting it, and the screen that
  follows has no retry button and no *go back and change your answer*: a door that
  reopens on the same screen isn't a door.

  ## Turning someone away costs nothing to store

  A refused signup keeps **no personal data at all** — `Accounts.register/2` checks
  attestation before it touches the database, so no row is created and the invite isn't
  redeemed. Holding records on someone we've just refused would be the wrong trade, and
  a device-local flag is enough for a best-effort block.

  The invite surviving matters too: whoever sent it can pass it on, and nobody has to
  ask us for a replacement they shouldn't have needed.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias Polyphony.Accounts
  alias Polyphony.Accounts.Consent
  alias PolyphonyWeb.{Auth, Kit, Layouts}

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sign up",
       first?: Accounts.count() == 0,
       error: nil,
       field: nil,
       turned_away: false,
       attest: false,
       consent: false
     )}
  end

  def handle_event("toggle", %{"field" => "attest"}, socket),
    do: {:noreply, assign(socket, attest: not socket.assigns.attest, error: nil, field: nil)}

  def handle_event("toggle", %{"field" => "consent"}, socket),
    do: {:noreply, assign(socket, consent: not socket.assigns.consent, error: nil, field: nil)}

  def handle_event("register", params, socket) do
    # Logged unconditionally so the server logs prove the click reached the server (a
    # stuck button is usually the socket not connecting — then this line never appears).
    Logger.info("[signup] register submitted for username=#{inspect(params["username"])}")

    safe(socket, fn ->
      attrs = %{
        email: params["email"],
        username: params["username"],
        attested_adult: socket.assigns.attest,
        accepted_consents: if(socket.assigns.consent, do: Consent.required_documents(), else: []),
        invite_token: params["invite_token"]
      }

      case Accounts.register(attrs) do
        {:ok, user} ->
          Logger.info("[signup] registered user id=#{inspect(user.id)} role=#{user.role}")
          {:noreply, redirect(socket, to: ~p"/auth/verify/#{Auth.sign_token(user.id)}")}

        {:error, :attestation_required} ->
          # Ends the signup rather than restricting it. Nothing was stored.
          Logger.warning("[signup] registration rejected: :attestation_required")
          {:noreply, assign(socket, turned_away: true)}

        {:error, reason} ->
          Logger.warning("[signup] registration rejected: #{inspect(reason)}")
          {:noreply, assign(socket, error: message(reason), field: field(reason))}
      end
    end)
  end

  defp field(:invite_required), do: :invite
  defp field(:invite_invalid), do: :invite

  defp field(%Ecto.Changeset{} = cs) do
    cond do
      cs.errors[:username] -> :username
      cs.errors[:email] -> :email
      true -> nil
    end
  end

  defp field(_), do: nil

  defp message(:invite_required), do: "Polyphony is invite-only while it's young."

  defp message(:invite_invalid),
    do: "This one's been used. Invites work once — ask whoever sent it for another."

  defp message(:consent_required), do: "We need this one before we can make you an account."
  defp message(%Ecto.Changeset{} = cs), do: changeset_message(cs)
  defp message(_other), do: "That didn't work — check your details and try again."

  defp changeset_message(cs) do
    cond do
      cs.errors[:username] -> "Taken. Try something else."
      cs.errors[:email] -> "There's already an account on that address."
      true -> "Check your details and try again."
    end
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  def render(%{turned_away: true} = assigns) do
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

  def render(assigns) do
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
              placeholder="A name other people will see"
              class="field px-3 py-2.5 text-[14px] w-full"
              style={@field == :username && "border-color:var(--pencil)"}
            />
            <.field_error :if={@field == :username} message={@error} />
          </Kit.row>

          <div class="px-5 py-4">
            <%!-- Not a content preference: leaving this unchecked ends the signup. --%>
            <div class="flex items-start gap-2.5 mb-3">
              <Kit.chk
                state={if @attest, do: :on, else: :off}
                phx-click="toggle"
                phx-value-field="attest"
              />
              <div>
                <div class="text-[13px] leading-snug">I'm 18 or over</div>
                <div class="text-[11px] leading-relaxed dim mt-0.5">
                  Polyphony is for adults. We can't offer it to under-18s yet.
                </div>
              </div>
            </div>

            <div class="flex items-start gap-2.5 mb-4">
              <Kit.chk
                state={if @consent, do: :on, else: :off}
                phx-click="toggle"
                phx-value-field="consent"
              />
              <div class="text-[13px] leading-snug">
                I've read the <span class="underline">terms</span> and the
                <span class="underline">privacy notice</span>
              </div>
            </div>

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
