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

  ## Two modes

  * **Standalone** — args carry `messages` (or fall back to a seed). The job
    returns an Oban result reflecting the outcome (`:ok`, `{:cancel, …}`,
    `{:error, …}`), used for a one-off generation.

  * **Chained** (the beat loop) — args carry `chain: true`, a `beat_ref`, and the
    `remaining` cast. The job records the packet on the beat, then enqueues the
    next cast member serially, or, when the cast is exhausted, closes the beat and
    enqueues the next `RunBeat` per `BeatPolicy`. A failed character is recorded
    and the chain continues — the beat is not atomic and a silent character is
    survivable (§12), so a chained job returns `:ok` even on a generation failure.

  Failure handling maps to the §12 table: a refusal retries once on the heavy
  model (model-swap, not backoff), then fails; other errors are transport/schema
  and (in standalone mode) let Oban back off.
  """
  use Oban.Worker, queue: :generation, max_attempts: 3

  require Logger

  alias Polyphony.{App, Generation}
  alias Polyphony.Commands.CommitPacket
  alias Polyphony.Director.BeatOps
  alias Polyphony.Director.BeatPolicy
  alias Polyphony.Director.Commands.{RecordPacket, RecordFailure, CloseBeat}
  alias Polyphony.Jobs.RunBeat

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"scene_id" => scene_id, "character_id" => character_id, "beat" => beat} = args
    packet_id = args["packet_id"] || BeatOps.packet_id(scene_id, beat, character_id)

    messages =
      args["messages"] || BeatOps.messages_for(scene_id, beat, character_id, args["pacing_note"])

    opts = gen_opts(args)
    result = commit_turn(messages, {scene_id, character_id, beat, packet_id}, opts)

    if args["chain"], do: continue_chain(args, character_id, result), else: standalone(result)
  end

  # ── Generation + commit (shared by both modes) ───────────────────────────────

  # Returns :committed | {:cancelled, reason} | {:failed, reason}
  defp commit_turn(messages, {scene_id, character_id, beat, packet_id} = ids, opts) do
    case Generation.generate(messages, opts) do
      {:ok, packet} ->
        commit(scene_id, character_id, beat, packet_id, packet)
        :committed

      {:error, {:refusal, _text}} ->
        retry_on_heavy_model(messages, opts, ids)

      {:error, reason} ->
        Logger.warning("generation failed for #{character_id}@#{beat}: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  defp retry_on_heavy_model(messages, opts, {scene_id, character_id, beat, packet_id}) do
    heavy = get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])
    Logger.info("refusal for #{character_id}@#{beat}; retrying on #{heavy}")

    case Generation.generate(messages, Keyword.put(opts, :model, heavy)) do
      {:ok, packet} ->
        commit(scene_id, character_id, beat, packet_id, packet)
        :committed

      {:error, reason} ->
        Logger.warning("refusal persisted after model swap for #{character_id}@#{beat}")
        {:cancelled, {:refusal, reason}}
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

  # ── Standalone mode: map the outcome to an Oban result ───────────────────────

  defp standalone(:committed), do: :ok
  defp standalone({:cancelled, reason}), do: {:cancel, reason}
  defp standalone({:failed, reason}), do: {:error, reason}

  # ── Chained mode: beat bookkeeping + serial handoff ──────────────────────────

  defp continue_chain(args, character_id, result) do
    beat_ref = args["beat_ref"]
    record_outcome(beat_ref, args["beat"], character_id, result)

    case args["remaining"] do
      [next | rest] ->
        enqueue_cast(args, next, rest)

      _ ->
        App.dispatch(%CloseBeat{beat_ref: beat_ref})
        maybe_continue(args)
    end

    :ok
  end

  defp record_outcome(beat_ref, _beat, character_id, :committed) do
    App.dispatch(%RecordPacket{beat_ref: beat_ref, character_id: character_id})
  end

  defp record_outcome(beat_ref, _beat, character_id, {kind, reason})
       when kind in [:failed, :cancelled] do
    # Records the failure on the beat (§12). PacketFailed carries scene_id + beat,
    # so it surfaces to the user as generation.failed ("Mira didn't respond");
    # no character ever sees it.
    App.dispatch(%RecordFailure{
      beat_ref: beat_ref,
      character_id: character_id,
      reason: inspect(reason)
    })
  end

  defp enqueue_cast(args, %{"character_id" => id} = member, rest) do
    args
    |> Map.merge(%{
      "character_id" => id,
      "packet_id" => BeatOps.packet_id(args["scene_id"], args["beat"], id),
      "pacing_note" => member["pacing_note"],
      "remaining" => rest,
      "messages" => nil
    })
    |> __MODULE__.new()
    |> Oban.insert!()
  end

  defp maybe_continue(args) do
    next =
      BeatPolicy.next(%{
        depth: args["depth"] || 0,
        control: parse_control(args["control"]),
        membership_changed: false,
        max_depth: args["max_depth"] || BeatPolicy.default_max_depth()
      })

    if next == :continue do
      args
      |> Map.merge(%{"beat" => args["beat"] + 1, "depth" => (args["depth"] || 0) + 1})
      |> Map.drop([
        "character_id",
        "packet_id",
        "remaining",
        "beat_ref",
        "chain",
        "pacing_note",
        "messages"
      ])
      |> RunBeat.new()
      |> Oban.insert!()
    end
  end

  defp parse_control("continue"), do: :continue
  defp parse_control(:continue), do: :continue
  defp parse_control(_), do: :yield_to_user

  # ── Opts ─────────────────────────────────────────────────────────────────────

  defp gen_opts(args) do
    []
    |> maybe_put(:provider, BeatOps.resolve_provider(args["provider"]))
    |> maybe_put(:model, args["model"])
    |> maybe_put(:max_tokens, args["max_tokens"])
    |> maybe_put(:thinking, args["thinking"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
