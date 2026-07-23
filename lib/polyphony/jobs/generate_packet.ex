defmodule Polyphony.Jobs.GeneratePacket do
  @moduledoc """
  Generate one character's turn and commit it (§15 slice 3; foundational rules
  1–2).

  This is the *only* place a character generation happens: an Oban job, outside
  any aggregate. It calls `Polyphony.Generation`, then dispatches a `CommitPacket`
  command — the job produces a command, the aggregate validates it. Replaying the
  event log never re-runs this job.

  `packet_id` is derived deterministically upstream `(branch, beat, character_id)`
  and passed in args, so a job that crashes after the API call but before Oban
  records completion re-runs, regenerates, and the aggregate commits exactly once
  (§12 idempotency).

  Failure handling maps to the §12 table:

    * refusal → retry once on the heavy model (model-swap is the remediation, not
      Oban backoff — the same model reliably refuses again); still refused →
      `{:cancel, …}` so it does not burn retries
    * schema-invalid / empty / transport → returned as errors; Oban backs off up
      to `max_attempts`

  (Emitting a `GenerationFailed` event on terminal failure is wired in with the
  Beat/Director slice, which owns the beat's lifecycle.)
  """
  use Oban.Worker, queue: :generation, max_attempts: 3

  require Logger

  alias Polyphony.{App, Generation}
  alias Polyphony.Commands.CommitPacket

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "scene_id" => scene_id,
      "character_id" => character_id,
      "beat" => beat,
      "packet_id" => packet_id
    } = args

    messages = args["messages"] || default_messages(args)
    opts = gen_opts(args)

    case Generation.generate(messages, opts) do
      {:ok, packet} ->
        commit(scene_id, character_id, beat, packet_id, packet)

      {:error, {:refusal, _text}} ->
        retry_on_heavy_model(messages, opts, scene_id, character_id, beat, packet_id)

      {:error, reason} ->
        Logger.warning("generation failed for #{character_id}@#{beat}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp retry_on_heavy_model(messages, opts, scene_id, character_id, beat, packet_id) do
    heavy = get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])
    Logger.info("refusal for #{character_id}@#{beat}; retrying on #{heavy}")

    case Generation.generate(messages, Keyword.put(opts, :model, heavy)) do
      {:ok, packet} ->
        commit(scene_id, character_id, beat, packet_id, packet)

      {:error, reason} ->
        # A refusal survives the model swap: don't Oban-retry (it will refuse
        # again). Cancel and log distinctly (§12: a pattern is a signal to change
        # the default model).
        Logger.warning("refusal persisted after model swap for #{character_id}@#{beat}")
        {:cancel, {:refusal, reason}}
    end
  end

  defp commit(scene_id, character_id, beat, packet_id, packet) do
    App.dispatch(%CommitPacket{
      scene_id: scene_id,
      character_id: character_id,
      beat: beat,
      packet_id: packet_id,
      packet: packet
    })
  end

  defp gen_opts(args) do
    []
    |> maybe_put(:model, args["model"])
    |> maybe_put(:max_tokens, args["max_tokens"])
    |> maybe_put(:thinking, args["thinking"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # The stable→volatile assembler is `Polyphony.Context`: the Director
  # materializes a scene's cached prefix once and passes assembled `messages` in
  # the job args (slice 5 wires that path). This minimal seed is the fallback
  # when a job is enqueued without them.
  defp default_messages(args) do
    [
      %{
        role: "system",
        content:
          "You are #{args["character_id"]}. Respond only with a valid TurnPacket JSON object."
      },
      %{role: "user", content: "It is your turn. Emit your packet."}
    ]
  end
end
