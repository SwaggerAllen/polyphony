defmodule Polyphony.Jobs.ExtractArc do
  @moduledoc """
  One participant's arc extraction as a retryable Oban job (§10, §12).

  Failure classification (§12): a schema-invalid extraction is *permanent* —
  `{:cancel, …}` so it doesn't burn retries — while a transport/provider error is
  transient and returns `{:error, …}` for Oban to back off. Success stores the
  proposed entries.
  """
  use Oban.Worker, queue: :scene_close, max_attempts: 3

  alias Polyphony.{SceneClose, Failures}
  alias Polyphony.Director.BeatOps

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"scene_id" => scene_id, "character_id" => character_id} = args} = job
      ) do
    opts =
      case BeatOps.resolve_provider(args["provider"]) do
        nil -> []
        mod -> [provider: mod]
      end

    case SceneClose.extract_participant(scene_id, character_id, opts) do
      {:ok, _n} ->
        :ok

      {:cancel, reason} ->
        # Schema-invalid: permanent. Surface it (retryable, not editable).
        record(job, scene_id, character_id, :schema, reason, args)
        {:cancel, reason}

      {:error, reason} = err ->
        if job.attempt >= job.max_attempts,
          do: record(job, scene_id, character_id, :transport, reason, args)

        err
    end
  end

  defp record(_job, scene_id, character_id, kind, reason, args) do
    Failures.record(
      worker: __MODULE__,
      scene_id: scene_id,
      subject: character_id,
      operation: :arc,
      kind: kind,
      reason: inspect(reason),
      editable: false,
      args: args
    )
  end
end
