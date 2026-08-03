defmodule PolyphonyWeb.DebugDrawerLive do
  @moduledoc """
  A floating **debug drawer** embedded in the root layout (a nested, sticky
  LiveView, so it rides along on every page — live or dead — and survives live
  navigation). It streams recent server log lines from `Polyphony.DebugLog` and
  offers **Copy** (whole buffer → clipboard, client-side) and **Clear**.

  Only mounted when `:debug_drawer` is enabled (env `DEBUG_DRAWER` in prod) — the
  root layout skips the `live_render` otherwise. It is a bring-up aid; keep it off
  in public prod (see `Polyphony.DebugLog`).
  """
  use Phoenix.LiveView

  alias Polyphony.{DebugFlags, DebugLog}
  alias PolyphonyWeb.Kit

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: DebugLog.subscribe()
    recent = DebugLog.recent()

    {:ok,
     socket
     |> assign(:count, length(recent))
     |> assign(:heavy, DebugFlags.get(:force_heavy))
     |> assign(:events, DebugFlags.get(:events))
     |> assign(:trace, DebugFlags.get(:trace))
     |> stream(:logs, recent), layout: false}
  end

  @impl true
  def handle_info({:debug_log, entry}, socket) do
    {:noreply, socket |> stream_insert(:logs, entry) |> update(:count, &(&1 + 1))}
  end

  def handle_info(:debug_log_cleared, socket) do
    {:noreply, socket |> stream(:logs, [], reset: true) |> assign(:count, 0)}
  end

  @impl true
  def handle_event("clear", _params, socket) do
    # Broadcasts :debug_log_cleared, which our own handle_info/2 uses to reset.
    DebugLog.clear()
    {:noreply, socket}
  end

  # Toggle routing every chat generation to the heavy model (§9) — read by
  # `Polyphony.LLM.call`. Global, all sessions; a bring-up aid.
  def handle_event("toggle_heavy", _params, socket) do
    {:noreply, assign(socket, :heavy, DebugFlags.toggle(:force_heavy))}
  end

  # Toggle the play view's raw event / beat-boundary stream (broadcast to it).
  def handle_event("toggle_events", _params, socket) do
    {:noreply, assign(socket, :events, DebugFlags.toggle(:events))}
  end

  # Toggle capturing actual LLM requests/responses into the play view's debug pane.
  def handle_event("toggle_trace", _params, socket) do
    {:noreply, assign(socket, :trace, DebugFlags.toggle(:trace))}
  end

  # Colour by meaning, off the kit's semantic tokens — the mocks' own rule, and why
  # the drawer needs no palette of its own.
  #
  # `level` arrives from the Erlang logger as an **atom**, not a string.
  defp level_style(:error), do: "color:var(--pencil)"
  defp level_style(:warning), do: "color:var(--lamp)"
  defp level_style(_), do: "color:var(--bcm)"

  # A magic-link URL is one long unbroken token; without the wrap it forces the panel
  # wider than the screen and takes the rest of the log with it. Inline rather than a
  # Tailwind arbitrary utility, which its content scan does not pick up out of a
  # `~H` sigil — and inline `style` off a token is the mocks' own idiom anyway.
  @wrap "overflow-wrap:anywhere;"

  # Severity outranks the mail tint: a failed send has to read as an error, not as
  # one more mail line.
  defp msg_style(%{level: :error}), do: @wrap <> "color:var(--pencil)"
  defp msg_style(e), do: @wrap <> if(mail?(e), do: "color:var(--secret)", else: "")

  # The mail trail is what the drawer is most often opened for — picked out of the
  # stream rather than left to be scrolled for. `Notifications` and `Auth` both tag
  # their lines `[mail]`.
  defp mail?(%{message: msg}) when is_binary(msg), do: String.contains?(msg, "[mail]")
  defp mail?(_), do: false

  @impl true
  def render(assigns) do
    #
    # Open/close, copy, and the socket-status indicator are driven by plain JS
    # (see assets/js/app.js), not phx-click / hooks, so the drawer stays usable and
    # keeps reporting status even when the LiveView socket never connects — the very
    # failure the drawer exists to diagnose. `#socket-status` is phx-update="ignore"
    # so LiveView never clobbers what that JS writes. Clear is a server event (only
    # meaningful while connected).
    ~H"""
    <div id="debug-drawer" class="fr stage dark dock">
      <Kit.sheet id="debug-drawer-body" class="dock-panel">
        <Kit.row class="px-3 py-2 flex items-center flex-wrap gap-1.5" style="background:var(--b2)">
          <span class="mono text-[12px] font-semibold">Session log</span>
          <Kit.pill><%= @count %></Kit.pill>
          <%!-- Written by app.js, never by LiveView (phx-update="ignore"), so its
                colour is set inline from the kit's semantic tokens rather than by a
                class this template would have to own. --%>
          <span id="socket-status" class="pill" phx-update="ignore">connecting…</span>
          <span class="flex-1"></span>
          <Kit.btn size={:sm} kind={if @heavy, do: :primary, else: :ghost} type="button"
                   phx-click="toggle_heavy"
                   title="Route every generation to the heavy model">
            Heavy: <%= if @heavy, do: "on", else: "off" %>
          </Kit.btn>
          <Kit.btn size={:sm} kind={if @events, do: :primary, else: :ghost} type="button"
                   phx-click="toggle_events"
                   title="Show the raw event / beat-boundary stream in the scene pane">
            Events: <%= if @events, do: "on", else: "off" %>
          </Kit.btn>
          <Kit.btn size={:sm} kind={if @trace, do: :primary, else: :ghost} type="button"
                   phx-click="toggle_trace"
                   title="Capture actual LLM requests/responses into the scene pane">
            Trace: <%= if @trace, do: "on", else: "off" %>
          </Kit.btn>
          <Kit.btn size={:sm} kind={:ghost} type="button" id="debug-copy">Copy</Kit.btn>
          <Kit.btn size={:sm} kind={:ghost} type="button" phx-click="clear">Clear</Kit.btn>
          <Kit.btn size={:sm} kind={:ghost} type="button" id="debug-drawer-close">✕</Kit.btn>
        </Kit.row>

        <Kit.empty :if={@count == 0} headline="Nothing logged yet." class="py-6">
          Anything the server logs shows up here, newest last.
        </Kit.empty>

        <div id="debug-log-list" class="scroller px-3 py-1.5" phx-hook="Autoscroll" phx-update="stream">
          <Kit.row
            :for={{id, e} <- @streams.logs}
            id={id}
            class="flex gap-2 py-1 text-[11.5px] leading-[1.5]"
          >
            <span class="mono dim shrink-0"><%= e.time %></span>
            <span class="lbl shrink-0 pt-[.15rem]" style={level_style(e.level)}><%= e.level %></span>
            <%!-- Kept on one line: `whitespace-pre-wrap` is wanted (multi-line
                  `inspect/1` output stays readable) but it also preserves the
                  template's own indentation, which indents the first line of every
                  message halfway across the panel. --%>
            <span class="mono flex-1 whitespace-pre-wrap" style={msg_style(e)}><%= e.message %></span>
          </Kit.row>
        </div>
      </Kit.sheet>

      <Kit.btn kind={:ghost} type="button" id="debug-drawer-toggle" class="dock-tab rounded-full px-3.5">
        ⚙ log <Kit.pill><%= @count %></Kit.pill>
        <span id="socket-status-toggle" class="dot" phx-update="ignore"></span>
      </Kit.btn>
    </div>
    """
  end
end
