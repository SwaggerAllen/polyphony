defmodule PolyphonyWeb.Layouts do
  @moduledoc "Root + app layouts. Templates are inline (HEEx) to avoid a template dir."
  use PolyphonyWeb, :html

  def render("root.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title><%= assigns[:page_title] || "Polyphony" %></title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body>
        <%= @inner_content %>
      </body>
    </html>
    """
  end

  def render("app.html", assigns) do
    assigns = assign_new(assigns, :current_user, fn -> nil end)

    ~H"""
    <header class="topbar">
      <a class="brand" href={~p"/"}>Polyphony</a>
      <div class="spacer"></div>
      <nav>
        <%= if @current_user do %>
          <a href={~p"/library"}>Library</a>
          <a href={~p"/settings"}>Settings</a>
          <%= if @current_user.role in ["admin", "superadmin"] do %>
            <a href={~p"/admin"}>Admin</a>
          <% end %>
          <a href={~p"/logout"}>@<%= @current_user.username %> · out</a>
        <% else %>
          <a href={~p"/login"}>Sign in</a>
        <% end %>
      </nav>
    </header>

    <main class="wrap">
      <.flash_group flash={@flash} />
      <%= @inner_content %>
    </main>
    """
  end
end
