defmodule PolyphonyWeb.Telemetry do
  @moduledoc """
  Telemetry supervision, and the metric definitions LiveDashboard renders at
  `/admin/dashboard`.

  **Every metric here corresponds to an event something actually emits** — a chart
  that is permanently empty is worse than an absent one, because it reads as "nothing
  is happening" rather than "nothing is measured". Oban, Ecto, Phoenix and
  `telemetry_poller` publish theirs out of the box; `polyphony.llm.*` is ours, from the
  span in `Polyphony.LLM.call/2`.

  **Generation is the thing worth measuring.** A beat fans out to one LLM call per cast
  member, each of which can be slow, blank, refused, or capped, and none of it appears
  in a request duration — the work happens in an Oban job long after the response went
  out. `oban.job.*` sees the job; `polyphony.llm.*` sees the call inside it.

  A ten-minute backlog is kept by `PolyphonyWeb.Telemetry.History`, so the charts are
  already populated when the page opens — without it the dashboard only draws what
  happens while you watch, which is no use for something that already went wrong.
  """
  use Supervisor

  import Telemetry.Metrics

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    # `telemetry_poller`'s own application starts a default poller that emits the
    # `[:vm, …]` events below, so there is nothing to add here for those.
    Supervisor.init([PolyphonyWeb.Telemetry.History], strategy: :one_for_one)
  end

  @doc "Metric definitions rendered by the dashboard's Metrics tab."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # ── Generation ────────────────────────────────────────────────────────────
      #
      # Bucketed rather than averaged. Generation latency is not normally distributed:
      # a mean hides the tail that decides whether a beat feels alive or stalled, and
      # the tail is the entire question.
      distribution("polyphony.llm.call.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider],
        reporter_options: [buckets: [250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]],
        description: "Provider round trip for one call"
      ),
      counter("polyphony.llm.call.stop.duration",
        tags: [:provider, :outcome],
        description: "Completed calls, by provider and whether they returned usable text"
      ),
      counter("polyphony.llm.call.exception.duration",
        tags: [:provider],
        description: "Calls that raised rather than returned an error"
      ),
      # The circuit breaker firing looks exactly like generation breaking, from the
      # outside. It should be readable as a number rather than diagnosed.
      counter("polyphony.llm.blocked.count",
        tags: [:usage_kind],
        description: "Calls refused by the spend cap (§B5) — never reached a provider"
      ),

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
