defmodule Polyphony.DebugTap do
  @moduledoc """
  A per-scene ring buffer of the **actual LLM requests and responses** — the Director's
  decision calls and each character's generation — for the debug pane.

  `Polyphony.LLM.call` records here (best-effort) when the `:trace` debug flag is on and
  the call carries a `:scene_id`, so authoring/off-scene calls are ignored. Entries are
  capped per scene and kept newest-first; a change broadcasts on a per-scene topic so the
  play view refreshes. Pure diagnostics — nothing here feeds fiction, and it's a bring-up
  aid (keep the drawer off in public prod).

  Backed by a public ETS table so the play view reads it without a GenServer round-trip;
  writes go through the GenServer so concurrent jobs can't clobber a scene's buffer.
  """
  use GenServer

  @table __MODULE__
  @topic "debug:trace:"
  @max_per_scene 24

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @doc "Record one LLM call (async, best-effort). `entry` must carry `:scene_id`."
  def record(entry) when is_map(entry), do: GenServer.cast(__MODULE__, {:record, entry})

  @doc "The scene's recent LLM calls, newest first."
  def recent(scene_id) do
    case :ets.lookup(@table, key(scene_id)) do
      [{_, entries}] -> entries
      [] -> []
    end
  end

  @doc "Subscribe to a scene's trace updates."
  def subscribe(scene_id), do: Phoenix.PubSub.subscribe(Polyphony.PubSub, topic(scene_id))

  @doc false
  # Test aid: a synchronous call flushes any queued `record/1` casts (FIFO mailbox).
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def handle_call(:flush, _from, table), do: {:reply, :ok, table}

  @impl true
  def handle_cast({:record, %{scene_id: scene_id} = entry}, table) do
    key = key(scene_id)

    existing =
      case :ets.lookup(table, key) do
        [{_, entries}] -> entries
        [] -> []
      end

    :ets.insert(table, {key, Enum.take([entry | existing], @max_per_scene)})
    Phoenix.PubSub.broadcast(Polyphony.PubSub, topic(scene_id), {:debug_trace, scene_id})
    {:noreply, table}
  end

  def handle_cast(_other, table), do: {:noreply, table}

  defp key(scene_id), do: to_string(scene_id)
  defp topic(scene_id), do: @topic <> to_string(scene_id)
end
