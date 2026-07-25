defmodule PolyphonyWeb.HomeLive do
  @moduledoc "Landing page (V-none): the pitch + the way in."
  use PolyphonyWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Polyphony")}

  def render(assigns) do
    ~H"""
    <div class="card">
      <h1>Polyphony</h1>
      <p class="dim">
        An event-sourced, multi-agent roleplay engine. One agent per character plus a
        world Director; every character sees only their <em>filtered</em> slice of the
        story. Dramatic irony is structural — a property of the data, never a prompt.
      </p>
      <div class="row">
        <%= if @current_user do %>
          <a class="btn" href={~p"/library"}>Your library</a>
        <% else %>
          <a class="btn" href={~p"/signup"}>Create an account</a>
          <a class="btn ghost" href={~p"/login"}>Sign in</a>
        <% end %>
        <a class="btn ghost" href={~p"/browse"}>Browse published</a>
      </div>
    </div>
    """
  end
end
