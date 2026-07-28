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

  alias Polyphony.DebugLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: DebugLog.subscribe()
    recent = DebugLog.recent()

    {:ok,
     socket
     |> assign(:count, length(recent))
     |> assign(:heavy, force_heavy?())
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

  # Toggle routing every chat generation to the heavy model (§9) — a global debug
  # lever read by `Polyphony.LLM.call`. Affects all sessions; it's a bring-up aid.
  def handle_event("toggle_heavy", _params, socket) do
    heavy = not force_heavy?()
    Application.put_env(:polyphony, :force_heavy_model, heavy)
    {:noreply, assign(socket, :heavy, heavy)}
  end

  defp force_heavy?, do: Application.get_env(:polyphony, :force_heavy_model, false)

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
    <div id="debug-drawer" class="debug-drawer">
      <div id="debug-drawer-body" class="debug-drawer-body" style="display:none;">
        <div class="debug-drawer-head">
          <span class="debug-title">Session log</span>
          <span class="debug-count"><%= @count %></span>
          <span id="socket-status" class="socket-status connecting" phx-update="ignore">connecting…</span>
          <div class="spacer"></div>
          <button
            type="button"
            class={"btn sm #{if @heavy, do: "", else: "ghost"}"}
            phx-click="toggle_heavy"
            title="Route every generation to the heavy model"
          >
            Heavy: <%= if @heavy, do: "on", else: "off" %>
          </button>
          <button type="button" class="btn sm ghost" id="debug-copy">Copy</button>
          <button type="button" class="btn sm ghost" phx-click="clear">Clear</button>
          <button type="button" class="btn sm ghost" id="debug-drawer-close">✕</button>
        </div>
        <div class="debug-empty" :if={@count == 0}>No log lines captured yet.</div>
        <div id="debug-log-list" class="debug-log-list" phx-hook="Autoscroll" phx-update="stream">
          <div
            :for={{id, e} <- @streams.logs}
            id={id}
            class={"debug-line lvl-#{e.level}"}
          >
            <span class="debug-time"><%= e.time %></span>
            <span class="debug-lvl"><%= e.level %></span>
            <span class="debug-msg"><%= e.message %></span>
          </div>
        </div>
      </div>

      <button type="button" id="debug-drawer-toggle" class="debug-drawer-toggle">
        ⚙ log <span class="debug-count"><%= @count %></span>
        <span id="socket-status-toggle" class="socket-dot connecting" phx-update="ignore"></span>
      </button>
    </div>
    """
  end
end
