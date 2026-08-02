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
        <%!-- The design kit's three faces (ux/polyphony-kit.css §2). They do semantic
              work, not decoration: Spectral names things — screen titles, campaign and
              scene names, character labels, Director narration — Archivo carries all
              prose, Plex Mono the beats, ids and money. Each has a system fallback in
              the kit's own font stacks, so the app degrades to a plain sans offline
              rather than breaking. Self-hosting these is a worthwhile follow-up. --%>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="crossorigin" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Spectral:wght@400;500;600&family=Archivo:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
        />
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body>
        <%= @inner_content %>
        <%= if debug_drawer?() && assigns[:conn] do %>
          <%= live_render(@conn, PolyphonyWeb.DebugDrawerLive, id: "debug-drawer", sticky: true) %>
        <% end %>
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
      <nav class="topnav">
        <input type="checkbox" id="nav-toggle" class="nav-toggle-cb" />
        <label for="nav-toggle" class="nav-toggle" aria-label="Menu" title="Menu">☰</label>
        <div class="nav-links">
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
        </div>
      </nav>
    </header>

    <main class="wrap">
      <.flash_group flash={@flash} />
      <%= @inner_content %>
    </main>
    """
  end

  # The debug drawer (server-log viewer) is a bring-up aid, off unless enabled.
  defp debug_drawer?, do: Application.get_env(:polyphony, :debug_drawer, false)
end
