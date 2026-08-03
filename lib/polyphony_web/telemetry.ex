defmodule PolyphonyWeb.Telemetry do
  @moduledoc """
  Telemetry supervision, and the metric definitions LiveDashboard renders at
  `/admin/dashboard`.

  **Every metric here corresponds to an event something already emits** — Ecto, Oban,
  Phoenix and `telemetry_poller` all publish these out of the box. Nothing in
  `Polyphony` itself emits telemetry yet, so there is deliberately no metric named
  after the domain: a chart that is permanently empty is worse than an absent one,
  because it reads as "nothing is happening" rather than "nothing is measured".

  The gap that leaves is worth naming. **Generation is the slow, expensive, failable
  part** — a beat fans out to one LLM call per cast member, each of which can be slow,
  blank, refused, or costly, and none of that appears in a request duration because the
  work happens in an Oban job long after the response went out. `oban.job.*` below sees
  the job, not the call inside it. Closing that means a `:telemetry.span` around
  `Polyphony.LLM.call/2`, which is small but is new instrumentation in the generation
  path, so it is its own decision.

  History is not wired: LiveDashboard keeps what it observes while a tab is open and
  forgets the rest, which is the right trade for a bring-up tool. Anything worth
  retaining belongs in a reporter.
  """
  use Supervisor

  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    # `telemetry_poller`'s own application starts a default poller that emits the
    # `[:vm, …]` events below, so there is nothing to add here for those.
    Supervisor.init([], strategy: :one_for_one)
  end

  @doc "Metric definitions rendered by the dashboard's Metrics tab."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # ── Oban: where the beat loop actually runs ───────────────────────────────
      #
      # A beat *is* jobs. If they stall, queue, or die the scene stops, and no HTTP
      # metric shows it — the request that started it succeeded long before.
      summary("oban.job.stop.duration",
        unit: {:native, :millisecond},
        tags: [:worker],
        description: "Job execution time — generation lives in here"
      ),
      summary("oban.job.stop.queue_time",
        unit: {:native, :millisecond},
        tags: [:queue],
        description: "Waiting before running: the first sign of saturation"
      ),
      counter("oban.job.exception.duration",
        tags: [:worker],
        description: "Jobs that failed"
      ),

      # ── Ecto: upstream of conditioning, not just of page loads ────────────────
      #
      # A character's context is assembled from the log and pgvector on every turn,
      # so query time is upstream of how a scene *feels*.
      summary("polyphony.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "Query time, end to end"
      ),
      summary("polyphony.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "Waiting for a connection — the first sign the pool is small"
      ),
      summary("polyphony.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "Decoding results — where a wide payload shows up"
      ),

      # ── Phoenix ───────────────────────────────────────────────────────────────
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      # A LiveView slow to mount is a screen that looks broken.
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond}
      ),

      # ── VM ────────────────────────────────────────────────────────────────────
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end
end
