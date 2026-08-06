defmodule Polyphony.Broadcast.Activity do
  @moduledoc """
  The last **busy** beat-loop phase per scene, so a viewer who arrives mid-beat sees it.

  `Broadcast.announce_progress/3` is a PubSub broadcast and nothing else: it reaches
  whoever is subscribed at the instant it fires and leaves no trace. So the placeholder
  only ever appeared for someone who was already watching. Reload the page, follow a
  link back into the scene, or lose the connection for a moment while the Director is
  deciding, and the screen came back **idle** — no placeholder in the transcript, no
  waiting line in the strip, and Continue live, so a second beat could be raced into a
  scene that was already advancing. The one moment the indicator exists for is the one
  it was missing from.

  This is the same problem — and the same answer — as `PolyphonyWeb.Telemetry.History`:
  a short in-memory window so the screen is populated on open rather than only drawing
  what happens while you watch.

  ## What it holds, and what it deliberately doesn't

  One fact per scene: *the loop is working, on this*. Only `:director` and
  `:generating` are kept; every other phase clears the row.

  `:awaiting_user` is not restored, and that is a decision rather than an omission. It
  isn't a spinner — `PlayLive.take_turn/3` reads it to route the author's turn *into
  that paused slot*, at that beat. Restoring one that had since been walked on would
  commit a packet into a closed beat, which is worse than the pause being forgotten.
  Reconstructing it wants the beat aggregate's own state, not a cache.

  ## Losing it is the safe direction

  In memory, gone on restart, and busy rows expire after five minutes — comfortably
  longer than a model call (60s, plus at most one heavy-model retry) and short enough
  that a job which dies without announcing anything can't wedge a scene's screen. Every
  way this can be wrong ends in "idle", i.e. today's behaviour, never in a placeholder
  that never leaves.

  Writes go straight to the public table. The process owns it and prunes on a timer.
  """
  use GenServer

  @table __MODULE__
  # The phases that mean "something is running". `:awaiting_user` and `:idle` don't.
  @busy [:director, :generating]
  @stale_ms :timer.minutes(5)
  @prune_every :timer.minutes(1)

  @type phase :: :director | :generating
  @type entry :: %{phase: phase(), subject: term(), beat: term()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Record a phase for `scene_id`. A non-busy phase clears whatever was there.

  Called from `Broadcast.announce_progress/3`, which is best-effort — so this never
  raises, including when the table's owner is restarting.
  """
  @spec put(term(), atom(), keyword()) :: :ok
  def put(scene_id, phase, opts \\ [])

  def put(scene_id, phase, opts) when phase in @busy do
    :ets.insert(@table, {key(scene_id), phase, opts[:subject], opts[:beat], now()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(scene_id, _phase, _opts) do
    :ets.delete(@table, key(scene_id))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "What the loop is doing in `scene_id` right now, or nil if nothing (or too old)."
  @spec get(term()) :: entry() | nil
  def get(scene_id) do
    case :ets.lookup(@table, key(scene_id)) do
      [{_key, phase, subject, beat, at}] ->
        if now() - at <= @stale_ms, do: %{phase: phase, subject: subject, beat: beat}

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now() - @stale_ms
    :ets.select_delete(@table, [{{:_, :_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_prune()
    {:noreply, state}
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_every)

  defp key(scene_id), do: to_string(scene_id)

  # Monotonic, so a clock change can't make a live beat look stale (or vice versa).
  defp now, do: System.monotonic_time(:millisecond)
end
