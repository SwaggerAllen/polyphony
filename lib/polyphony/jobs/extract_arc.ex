defmodule Polyphony.Jobs.ExtractArc do
  @moduledoc """
  One participant's arc extraction as a retryable Oban job (§10, §12).

  Failure classification (§12): a schema-invalid extraction is *permanent* —
  `{:cancel, …}` so it doesn't burn retries — while a transport/provider error is
  transient and returns `{:error, …}` for Oban to back off. Success stores the
  proposed entries.
  """
  use Oban.Worker, queue: :scene_close, max_attempts: 3

  alias Polyphony.SceneClose
  alias Polyphony.Director.BeatOps

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scene_id" => scene_id, "character_id" => character_id} = args}) do
    opts =
      case BeatOps.resolve_provider(args["provider"]) do
        nil -> []
        mod -> [provider: mod]
      end

    case SceneClose.extract_participant(scene_id, character_id, opts) do
      {:ok, _n} -> :ok
      {:cancel, reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
