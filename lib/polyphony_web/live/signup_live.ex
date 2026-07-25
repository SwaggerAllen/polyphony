defmodule PolyphonyWeb.SignupLive do
  @moduledoc """
  V11 (auth) sign-up. Enforces the §B2 gates through `Accounts.register/2`: 18+
  attestation, current consent, and a single-use invite — except the first account,
  which bootstraps as superadmin. On success we mint a magic-link token and redirect
  through the verify controller to establish the session.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.Accounts
  alias Polyphony.Accounts.Consent
  alias PolyphonyWeb.Auth

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Sign up", first?: Accounts.count() == 0, error: nil)}
  end

  def handle_event("register", params, socket) do
    attrs = %{
      email: params["email"],
      username: params["username"],
      attested_adult: params["attest"] == "true",
      accepted_consents:
        if(params["consent"] == "true", do: Consent.required_documents(), else: []),
      invite_token: params["invite_token"]
    }

    case Accounts.register(attrs) do
      {:ok, user} ->
        {:noreply, redirect(socket, to: ~p"/auth/verify/#{Auth.sign_token(user.id)}")}

      {:error, reason} ->
        {:noreply, assign(socket, error: message(reason))}
    end
  end

  defp message(:attestation_required), do: "You must confirm you are 18 or older."

  defp message(:invite_required),
    do: "Sign-up is invite-only right now — an invite link is required."

  defp message(:invite_invalid), do: "That invite link is invalid or already used."

  defp message(:consent_required),
    do: "Please accept the content policy, terms, and privacy notice."

  defp message(%Ecto.Changeset{} = cs), do: changeset_message(cs)
  defp message(other), do: "Could not sign up (#{inspect(other)})."

  defp changeset_message(cs) do
    cond do
      cs.errors[:email] ->
        "That email is taken or invalid."

      cs.errors[:username] ->
        "That username is taken or invalid (3–32 letters/numbers/underscore)."

      true ->
        "Please check your details."
    end
  end

  def render(assigns) do
    ~H"""
    <div class="card">
      <h1>Create your account</h1>
      <p :if={@first?} class="dim">You're the first user — you'll be the superadmin.</p>
      <div :if={@error} class="flash error"><%= @error %></div>

      <form phx-submit="register">
        <label for="email">Email <span class="faint">(never shown publicly)</span></label>
        <input type="email" name="email" id="email" required />

        <label for="username">Username <span class="faint">(your public handle)</span></label>
        <input type="text" name="username" id="username" required minlength="3" maxlength="32" />

        <label :if={not @first?} for="invite_token">Invite code</label>
        <input :if={not @first?} type="text" name="invite_token" id="invite_token" />

        <label class="row" style="align-items:center;gap:.5rem;margin-top:1rem;">
          <input type="checkbox" name="attest" value="true" style="width:auto;" /> I am 18 years or older.
        </label>
        <label class="row" style="align-items:center;gap:.5rem;">
          <input type="checkbox" name="consent" value="true" style="width:auto;" />
          I accept the content policy, terms, and privacy notice.
        </label>

        <br />
        <button class="btn" type="submit">Sign up</button>
      </form>
      <p class="dim">Already have an account? <a href={~p"/login"}>Sign in</a>.</p>
    </div>
    """
  end
end
