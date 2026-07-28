defmodule PolyphonyWeb.LoginLive do
  @moduledoc """
  V11 (auth): magic-link sign-in, no passwords. Submitting an email sends a signed
  link through the notification path. In dev the link is surfaced here directly so
  the flow works with no mailer.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.Accounts
  alias PolyphonyWeb.Auth

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Sign in", sent: false, dev_link: nil)}
  end

  def handle_event("send", %{"email" => email}, socket) do
    safe(socket, fn ->
      case Accounts.get_by_email(email) do
        nil ->
          # Don't reveal whether an address exists; claim sent either way.
          {:noreply, assign(socket, sent: true, dev_link: nil)}

        user ->
          url = Auth.deliver_magic_link(user)
          {:noreply, assign(socket, sent: true, dev_link: dev_link(url))}
      end
    end)
  end

  # In dev we surface the link; in prod it only goes to email.
  defp dev_link(url), do: if(Application.get_env(:polyphony, :env) == :prod, do: nil, else: url)

  def render(assigns) do
    ~H"""
    <div class="card">
      <h1>Sign in</h1>
      <%= if @sent do %>
        <p>If that email has an account, a sign-in link is on its way.</p>
        <%= if @dev_link do %>
          <p class="dim">Dev: <a href={@dev_link}>click to sign in</a></p>
        <% end %>
      <% else %>
        <form id="login-form" phx-submit="send">
          <label for="email">Email</label>
          <input type="email" name="email" id="email" required autofocus placeholder="you@example.com" />
          <br /><br />
          <button class="btn" type="submit">Send magic link</button>
        </form>
        <p class="dim">No account? <a href={~p"/signup"}>Sign up</a>.</p>
      <% end %>
    </div>
    """
  end
end
