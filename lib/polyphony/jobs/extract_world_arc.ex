defmodule Polyphony.Jobs.ExtractWorldArc do
  @moduledoc """
  A scene's world-arc extraction as a retryable Oban job (§2.8, §10, §12) — the
  world counterpart to `Jobs.ExtractArc`, fanned out once per scene close.

  Same failure classification: a schema-invalid extraction is permanent
  (`{:cancel, …}`); a transport/provider error is transient (`{:error, …}` for Oban
  to back off). A scene with no campaign no-ops (`{:ok, 0}`).
  """
  use Oban.Worker, queue: :scene_close, max_attempts: 3

  alias Polyphony.{SceneClose, Failures}
  alias Polyphony.Director.BeatOps

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scene_id" => scene_id} = args} = job) do
    opts =
      case BeatOps.resolve_provider(args["provider"]) do
        nil -> []
        mod -> [provider: mod]
      end

    case SceneClose.extract_world(scene_id, opts) do
      {:ok, _n} ->
        :ok

      {:cancel, reason} ->
        record(scene_id, :schema, reason, args)
        {:cancel, reason}

      {:error, reason} = err ->
        if job.attempt >= job.max_attempts, do: record(scene_id, :transport, reason, args)
        err
    end
  end

  defp record(scene_id, kind, reason, args) do
    Failures.record(
      worker: __MODULE__,
      scene_id: scene_id,
      subject: "world",
      operation: :world_arc,
      kind: kind,
      reason: inspect(reason),
      editable: false,
      args: args
    )
  end
end
