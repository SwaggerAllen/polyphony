defmodule Polyphony.Context.Store do
  @moduledoc """
  A per-node cache of materialized `SceneContext`s, keyed by `(scene_id,
  character_id)`.

  The Oban jobs that generate a beat need each character's frozen prefix
  (§9), but that document should not be serialized through job args on every
  step. Instead it is materialized once at scene open and parked here; jobs fetch
  it by key. It is pure cache — rebuildable from the log and the authored layer —
  so losing it on restart only costs a re-materialization.

  Backed by a public ETS table so jobs read it directly without a GenServer
  round-trip.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @doc "Cache a character's materialized context for a scene."
  @spec put(term(), term(), Polyphony.Context.SceneContext.t()) :: :ok
  def put(scene_id, character_id, %Polyphony.Context.SceneContext{} = ctx) do
    :ets.insert(@table, {{key(scene_id), key(character_id)}, ctx})
    :ok
  end

  @doc "Fetch a character's cached context, if present."
  @spec fetch(term(), term()) :: {:ok, Polyphony.Context.SceneContext.t()} | :error
  def fetch(scene_id, character_id) do
    case :ets.lookup(@table, {key(scene_id), key(character_id)}) do
      [{_, ctx}] -> {:ok, ctx}
      [] -> :error
    end
  end

  defp key(id), do: to_string(id)
end
