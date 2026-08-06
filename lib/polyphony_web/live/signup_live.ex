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
  alias PolyphonyWeb.{Auth, Screens}

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

  def handle_event("register", params, socket) do
    # Logged unconditionally so the server logs prove the click reached the server (a
    # stuck button is usually the socket not connecting — then this line never appears).
    Logger.info("[signup] register submitted for username=#{inspect(params["username"])}")

    safe(socket, fn ->
      attest? = params["attest"] == "true"
      consent? = params["consent"] == "true"

      attrs = %{
        email: params["email"],
        username: params["username"],
        attested_adult: attest?,
        accepted_consents: if(consent?, do: Consent.required_documents(), else: []),
        invite_token: params["invite_token"]
      }

      # Kept on the socket so a rejected submit re-renders with the boxes as the person
      # left them. Nothing reads them to decide anything — the form did that.
      socket = assign(socket, attest: attest?, consent: consent?)

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
      cs.errors[:username] -> Screens.Signup.username_message(cs.errors[:username])
      cs.errors[:email] -> "There's already an account on that address."
      true -> "Check your details and try again."
    end
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Screens.Signup.screen
      turned_away={@turned_away}
      first?={@first?}
      field={@field}
      error={@error}
      attest={@attest}
      consent={@consent}
      current_user={@current_user}
    />
    """
  end
end
