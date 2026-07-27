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

  alias Phoenix.LiveView.JS
  alias Polyphony.DebugLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: DebugLog.subscribe()
    recent = DebugLog.recent()

    {:ok,
     socket
     |> assign(:count, length(recent))
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

  @impl true
  def render(assigns) do
    ~H"""
    <div id="debug-drawer" class="debug-drawer">
      <div id="debug-drawer-body" class="debug-drawer-body" style="display:none;">
        <div class="debug-drawer-head">
          <span class="debug-title">Session log</span>
          <span class="debug-count"><%= @count %></span>
          <div class="spacer"></div>
          <button
            type="button"
            class="btn sm ghost"
            id="debug-copy"
            phx-hook="CopyLog"
            data-target="debug-log-list"
          >
            Copy
          </button>
          <button type="button" class="btn sm ghost" phx-click="clear">Clear</button>
          <button
            type="button"
            class="btn sm ghost"
            phx-click={JS.hide(to: "#debug-drawer-body") |> JS.show(to: "#debug-drawer-toggle")}
          >
            ✕
          </button>
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

      <button
        type="button"
        id="debug-drawer-toggle"
        class="debug-drawer-toggle"
        phx-click={JS.show(to: "#debug-drawer-body") |> JS.hide(to: "#debug-drawer-toggle")}
      >
        ⚙ log <span class="debug-count"><%= @count %></span>
      </button>
    </div>
    """
  end
end
