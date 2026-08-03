defmodule PolyphonyWeb.Layouts do
  @moduledoc """
  Root + app layouts. Templates are inline (HEEx) to avoid a template dir.

  ## The shell is deliberately thin

  The design has **no persistent global chrome** (`ux/`): a screen fills the
  viewport and carries its own header, and going elsewhere is that header's back
  chevron or its overflow menu (`Kit.header/1`, `Kit.menu/1`). A standing nav bar
  would cost a row of vertical space on every screen of a product whose main
  surface is a transcript — and on the play screen it would sit above a layout
  that already accounts for the full viewport.

  So the app layout is a flash region and the screen. What used to be here — a
  sticky top bar with a brand, links and a hamburger — is gone with the first-cut
  design system it belonged to.

  ## `<body>` is the frame root

  The kit's tokens are defined by the register classes (`.fr stage dark`), so
  anything outside a frame has no colours at all. Putting the register on `<body>`
  gives the document a backdrop, the right type, and working tokens everywhere,
  and lets a screen nest its own frame to change register — which is exactly what
  play does when the viewer is a character (`.page`, reading) rather than the
  author (`.stage`, working).
  """
  use PolyphonyWeb, :html

  alias PolyphonyWeb.Kit

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
      <%!-- The register on the body is the document's backdrop and token source; a
            screen nests its own frame when it needs a different one. --%>
      <body class="fr stage dark min-h-[100dvh]">
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
    <%!-- Flashes float over the screen rather than displacing it: a screen that owns
          the viewport can't have a banner pushing its bottom bar off. --%>
    <div id="flash" class="fixed inset-x-0 top-0 z-50 p-3 flex flex-col gap-2 pointer-events-none">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>

    <main><%= @inner_content %></main>
    """
  end

  @doc """
  The overflow menu's contents — everywhere that isn't this screen.

  Lives here rather than in each screen so the set of destinations is defined once;
  a screen decides *whether* to show a menu, not what's in it.
  """
  attr(:current_user, :map, default: nil)

  def nav_menu(assigns) do
    ~H"""
    <Kit.menu :if={@current_user}>
      <:item navigate={~p"/library"}>Your stuff</:item>
      <:item navigate={~p"/browse"}>Browse published</:item>
      <:item navigate={~p"/settings"}>Settings</:item>
      <:item :if={@current_user.role in ["admin", "superadmin"]} navigate={~p"/admin"}>Admin</:item>
      <:item href={~p"/logout"}>Sign out, @<%= @current_user.username %></:item>
    </Kit.menu>
    """
  end

  # The debug drawer (server-log viewer) is a bring-up aid, off unless enabled.
  defp debug_drawer?, do: Application.get_env(:polyphony, :debug_drawer, false)
end
