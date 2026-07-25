defmodule Polyphony.Jobs.SummarizeScene do
  @moduledoc """
  One viewer's scene summary as a retryable Oban job (§10, §12).

  Summaries have no permanent failure mode — a blank/transport error is worth
  retrying — so a failure returns `{:error, …}` and Oban backs off up to
  `max_attempts`, after which the summary is simply missing and the character's
  next materialization falls back to their filtered verbatim scene.
  """
  use Oban.Worker, queue: :scene_close, max_attempts: 5

  alias Polyphony.{SceneClose, Failures}
  alias Polyphony.Director.BeatOps

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scene_id" => scene_id, "viewer" => viewer_key} = args} = job) do
    opts =
      []
      |> put_mod(:provider, args["provider"])
      |> put_mod(:embedder, args["embedder"])

    case SceneClose.summarize_viewer(scene_id, SceneClose.viewer_from_key(viewer_key), opts) do
      :ok ->
        :ok

      {:error, reason} = err ->
        # Summaries have no permanent failure mode: retry until exhausted, then
        # surface a retry affordance (§12).
        if job.attempt >= job.max_attempts do
          Failures.record(
            worker: __MODULE__,
            scene_id: scene_id,
            subject: viewer_key,
            operation: :summary,
            kind: :transport,
            reason: inspect(reason),
            editable: false,
            args: args
          )
        end

        err
    end
  end

  defp put_mod(opts, _key, nil), do: opts

  defp put_mod(opts, key, name) do
    case BeatOps.resolve_provider(name) do
      nil -> opts
      mod -> Keyword.put(opts, key, mod)
    end
  end
end
