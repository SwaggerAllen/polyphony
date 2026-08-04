defmodule PolyphonyWeb.Telemetry.History do
  @moduledoc """
  A ten-minute, in-memory backlog for LiveDashboard's Metrics tab.

  Without it the dashboard starts blank and only draws what happens while the tab is
  open — so opening it *after* something went wrong shows nothing about it, which is
  the one moment you actually want it. This keeps a short rolling window so the charts
  are already populated when the page loads.

  Ten minutes, in memory, and lost on restart, deliberately. That covers "what just
  happened", which is the question a bring-up dashboard answers. Anything longer is a
  time-series database wearing a disguise, and that is a service to run rather than a
  module to write.

  ## Shape

  Datapoints are extracted **at write time**, not stored raw. A raw backlog would keep
  every Ecto query's metadata — including the query text and params — alive for ten
  minutes, which is both large and more than anyone asked to retain. What lands in ETS
  is `{label, measurement}` and a timestamp: a few words per event.

  Writes go straight to a public ETS table rather than through the owning process. Ecto
  emits an event per query; a GenServer call on that path would be a bottleneck the
  moment the app is busy. The process owns the table and prunes on a timer, nothing
  more.

  ## Borrowed extraction

  `Phoenix.LiveDashboard.TelemetryListener.extract_datapoint_for_metric/4` does the
  measurement-and-label work for the live path, and this uses the same function so
  history and live points land on the same series. It is a private module
  (`@moduledoc false`), so `PolyphonyWeb.TelemetryHistoryTest` asserts it exists and
  still returns the shape expected — an upgrade that moves it fails a test rather than
  silently emptying the charts.
  """
  use GenServer

  require Logger

  alias Phoenix.LiveDashboard.TelemetryListener

  @table __MODULE__
  @window_ms :timer.minutes(10)
  @prune_every :timer.seconds(30)
  @handler "polyphony-metrics-history"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The `:metrics_history` callback — LiveDashboard applies this with the metric struct.

  Returns the last window's datapoints for that metric, oldest first, in the shape the
  Metrics page consumes: `%{label:, measurement:, time:}`.
  """
  @spec metrics_history(Telemetry.Metrics.t()) :: [
          %{label: String.t() | nil, measurement: number(), time: integer()}
        ]
  def metrics_history(metric) do
    cutoff = now() - @window_ms * 1_000
    key = key_for(metric)

    @table
    |> :ets.select([
      {{{:"$1", :"$2", :_}, :"$3", :"$4"}, [{:andalso, {:==, :"$1", key}, {:>=, :"$2", cutoff}}],
       [{{:"$2", :"$3", :"$4"}}]}
    ])
    |> Enum.sort()
    |> Enum.map(fn {time, label, measurement} ->
      %{label: label, measurement: measurement, time: time}
    end)
  rescue
    # A read must never take the dashboard down; an empty backlog is a fine answer.
    ArgumentError -> []
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    metrics = PolyphonyWeb.Telemetry.metrics()

    # One handler per distinct event, carrying only the metrics that event feeds — so
    # a handler does no work deciding what it is for.
    metrics
    |> Enum.group_by(& &1.event_name)
    |> Enum.each(fn {event, for_event} ->
      :telemetry.attach(
        "#{@handler}-#{Enum.join(event, "-")}",
        event,
        &__MODULE__.handle_event/4,
        for_event
      )
    end)

    schedule_prune()
    {:ok, %{}}
  end

  @doc false
  # Runs in the *emitting* process, so it does the least possible and never raises back
  # into whatever was being measured.
  def handle_event(_event, measurements, metadata, metrics) do
    time = System.system_time(:microsecond)

    for metric <- metrics,
        point =
          TelemetryListener.extract_datapoint_for_metric(metric, measurements, metadata, time) do
      :ets.insert(
        @table,
        {{key_for(metric), time, :erlang.unique_integer([:monotonic])}, point.label,
         point.measurement}
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = now() - @window_ms * 1_000

    :ets.select_delete(@table, [
      {{{:_, :"$1", :_}, :_, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    for event <- Enum.uniq(Enum.map(PolyphonyWeb.Telemetry.metrics(), & &1.event_name)) do
      :telemetry.detach("#{@handler}-#{Enum.join(event, "-")}")
    end

    :ok
  end

  # A metric is identified by everything that makes it a distinct series. Two metrics
  # can share an event name (a distribution and a counter over the same duration), and
  # they must not pool their datapoints.
  defp key_for(metric),
    do: :erlang.phash2({metric.__struct__, metric.name, metric.tags, metric.measurement})

  defp now, do: System.system_time(:microsecond)
  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_every)
end
