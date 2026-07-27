defmodule Polyphony.DebugLog do
  @moduledoc """
  In-memory ring buffer of recent log lines, surfaced to the browser by the debug
  drawer (`PolyphonyWeb.DebugDrawerLive`). A **bring-up / diagnostic tool** — off by
  default, gated by `:debug_drawer` (env `DEBUG_DRAWER` in prod). When enabled it is
  placed in the supervision tree and attaches an Erlang `:logger` handler so every
  log line that reaches the console (subject to the primary log level) is also
  captured here and pushed to any connected drawer over PubSub.

  Two roles in one module:

    * a **`:logger` handler** — `log/2` runs in the *logging* process, does the bare
      minimum (format + `GenServer.cast`), and never raises back into the logger;
    * a **GenServer** — owns the bounded buffer, broadcasts new entries, and answers
      `recent/0` / `clear/0`.

  ⚠ It exposes raw server logs to the browser, so keep it **off in public prod**
  (same posture as `SHOW_ERROR_DETAILS`). Logs can contain internal detail.
  """
  use GenServer
  require Logger

  @handler_id :polyphony_debug
  @topic "debug_log"
  @max_entries 500
  @max_msg_len 2_000

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Recent entries, oldest-first (ready to append to the drawer)."
  def recent, do: GenServer.call(__MODULE__, :recent)

  @doc "Drop every captured entry and notify subscribers (`:debug_log_cleared`)."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Subscribe the caller to new-entry / clear notices for the drawer."
  def subscribe, do: Phoenix.PubSub.subscribe(Polyphony.PubSub, @topic)

  def topic, do: @topic

  # ── :logger handler callback (runs in the logging process) ────────────────────

  @doc false
  def log(event, _config) do
    GenServer.cast(__MODULE__, {:push, build_entry(event)})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    attach_handler()
    {:ok, %{entries: [], seq: 0}}
  end

  @impl true
  def handle_call(:recent, _from, state) do
    # Stored newest-first; hand back oldest-first for natural top-to-bottom display.
    {:reply, Enum.reverse(state.entries), state}
  end

  def handle_call(:clear, _from, state) do
    safe_broadcast(:debug_log_cleared)
    {:reply, :ok, %{state | entries: []}}
  end

  @impl true
  def handle_cast({:push, entry}, state) do
    seq = state.seq + 1
    entry = Map.put(entry, :id, "log-#{seq}")
    entries = Enum.take([entry | state.entries], @max_entries)
    safe_broadcast({:debug_log, entry})
    {:noreply, %{state | entries: entries, seq: seq}}
  end

  @impl true
  def terminate(_reason, _state) do
    :logger.remove_handler(@handler_id)
    :ok
  end

  # ── Internals ─────────────────────────────────────────────────────────────────

  defp attach_handler do
    case :logger.add_handler(@handler_id, __MODULE__, %{}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      _ -> :ok
    end
  end

  defp safe_broadcast(msg) do
    Phoenix.PubSub.broadcast(Polyphony.PubSub, @topic, msg)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp build_entry(%{level: level, msg: msg, meta: meta}) do
    %{level: level, time: format_time(meta), message: msg |> format_message() |> truncate()}
  end

  # `{:string, chardata}` is the common Elixir case; the others cover Erlang reports
  # and `{format, args}` messages so nothing is dropped from the drawer.
  defp format_message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp format_message({:report, report}), do: inspect(report)

  defp format_message({format, args}) when is_list(args),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp format_message(other), do: inspect(other)

  defp format_time(%{time: t}) when is_integer(t) do
    t |> DateTime.from_unix!(:microsecond) |> Calendar.strftime("%H:%M:%S")
  rescue
    _ -> ""
  end

  defp format_time(_), do: ""

  defp truncate(str) when byte_size(str) > @max_msg_len,
    do: binary_part(str, 0, @max_msg_len) <> " …[truncated]"

  defp truncate(str), do: str
end
