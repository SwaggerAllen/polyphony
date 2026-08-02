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

  ## Modes

  * **Standalone** — args carry `messages` (or fall back to a seed). The job
    returns an Oban result reflecting the outcome (`:ok`, `{:cancel, …}`,
    `{:error, …}`), used for a one-off generation (e.g. a `Failures` retry).

  * **Chained** (the beat loop) — `chain: true`. An **autonomous** slot generates,
    commits, records the packet on the beat, then hands to `BeatDriver.advance/3`,
    which re-derives the next slot from the log and enqueues it (or pauses/closes).
    An **assisted** slot (`draft: true`) generates a **pending draft** and stops —
    the beat waits for the user to accept/discard (§A2). Serial ordering falls out
    of enqueue-next-on-completion; a failed character is recorded and the walk
    continues — the beat is not atomic (§12), so a chained job returns `:ok` even on
    a generation failure. The walk decision itself lives in `Director.BeatWalk`.

  Failure handling maps to the §12 table: a refusal retries once on the heavy
  model (model-swap, not backoff), then fails; other errors are transport/schema
  and (in standalone mode) let Oban back off.
  """
  use Oban.Worker, queue: :generation, max_attempts: 3

  require Logger

  alias Polyphony.Scene.Cast
  alias Polyphony.{App, Drafts, Generation, Failures}
  alias Polyphony.Commands.CommitPacket
  alias Polyphony.Director.{BeatOps, BeatDriver, BeatPolicy}
  alias Polyphony.Director.Commands.{RecordPacket, RecordFailure}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cond do
      # Chained assisted slot (§A2): generate a draft and pause for confirmation.
      args["chain"] && args["draft"] -> run_draft(args)
      # Chained autonomous slot (§A1): generate, commit, then walk the beat on.
      args["chain"] -> run_autonomous(args)
      # One-off (Failures retry, a single re-generation): map the outcome to Oban.
      true -> run_standalone(args)
    end
  end

  defp run_standalone(args) do
    %{"scene_id" => scene_id, "character_id" => character_id, "beat" => beat} = args
    packet_id = args["packet_id"] || BeatOps.packet_id(scene_id, beat, character_id)
    messages = messages_for(args)
    standalone(commit_turn(messages, {scene_id, character_id, beat, packet_id}, gen_opts(args)))
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
    # The campaign's heavy model wins; nil ⇒ the global `[:models, :heavy]`. The
    # `:heavy_model` opt is stripped before the provider call — it's routing, not a body
    # field. Falling back to the *same* model (heavy unset) would spin the refusal, so
    # only swap when a distinct heavy model exists.
    heavy =
      opts[:heavy_model] || get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])

    provider_opts = Keyword.delete(opts, :heavy_model)
    Logger.info("refusal for #{character_id}@#{beat}; retrying on #{heavy}")

    case Generation.generate(messages, Keyword.put(provider_opts, :model, heavy)) do
      {:ok, packet} ->
        commit(scene_id, character_id, beat, packet_id, packet)
        :committed

      {:error, reason} ->
        Logger.warning("refusal persisted after model swap for #{character_id}@#{beat}")
        {:cancelled, {:refusal, reason}}
    end
  end

  # The model writes whispers in the fiction's vocabulary — display names — because
  # that's what its prompt renders (§5.2 phase 2b-render). Resolve them to character
  # ids before the packet enters the log, so `addressed_to` routes on identity rather
  # than on a string that can be renamed out from under it.
  defp commit(scene_id, character_id, beat, packet_id, packet) do
    App.dispatch(%CommitPacket{
      scene_id: scene_id,
      character_id: character_id,
      beat: beat,
      packet_id: packet_id,
      packet: Cast.resolve_addressees(scene_id, packet)
    })
  end

  # ── Standalone mode: map the outcome to an Oban result ───────────────────────

  defp standalone(:committed), do: :ok
  defp standalone({:cancelled, reason}), do: {:cancel, reason}
  defp standalone({:failed, reason}), do: {:error, reason}

  # ── Chained mode: generate one slot, then walk the beat on (§A1/§A2) ──────────

  defp run_autonomous(args) do
    %{"scene_id" => scene_id, "character_id" => character_id, "beat" => beat} = args
    packet_id = args["packet_id"] || BeatOps.packet_id(scene_id, beat, character_id)
    messages = messages_for(args)
    result = commit_turn(messages, {scene_id, character_id, beat, packet_id}, gen_opts(args))

    record_outcome(args["beat_ref"], character_id, result)

    if match?({k, _} when k in [:failed, :cancelled], result),
      do: record_failure(args, character_id, result, messages)

    # Re-derive the next slot from the log and act — enqueue the next autonomous
    # generation, pause for a user/assisted slot, or close the beat.
    BeatDriver.advance(scene_id, beat, forward_ctx(args))
    :ok
  end

  # Assisted (§A2): generate, store a pending draft (draft.ready broadcast), and
  # STOP — the beat waits for the user to accept/discard, which resumes the walk. A
  # failed generation records the failure and the walk moves on.
  defp run_draft(args) do
    %{"scene_id" => scene_id, "character_id" => character_id, "beat" => beat} = args

    case Generation.generate(messages_for(args), gen_opts(args)) do
      {:ok, packet} ->
        Drafts.draft(scene_id, character_id, beat, packet, source: "assisted")
        :ok

      {:error, reason} ->
        Logger.warning("assisted draft failed for #{character_id}@#{beat}: #{inspect(reason)}")

        App.dispatch(%RecordFailure{
          beat_ref: args["beat_ref"],
          character_id: character_id,
          reason: inspect(reason)
        })

        BeatDriver.advance(scene_id, beat, forward_ctx(args))
        :ok
    end
  end

  defp messages_for(args) do
    args["messages"] ||
      BeatOps.messages_for(
        args["scene_id"],
        args["beat"],
        args["character_id"],
        args["pacing_note"]
      )
  end

  defp forward_ctx(args) do
    [
      provider: args["provider"],
      depth: args["depth"] || 0,
      max_depth: args["max_depth"] || BeatPolicy.default_max_depth(),
      control: parse_control(args["control"]),
      # Keep the campaign-owner attribution flowing to the next slot (§B5).
      user_id: args["user_id"],
      campaign_id: args["campaign_id"],
      # Keep the campaign LLM tuning flowing to the next slot (§9): token budget and
      # the workhorse/heavy models. `advance` re-keys `model` → `character_model`.
      character_max_tokens: args["character_max_tokens"],
      character_model: args["model"],
      heavy_model: args["heavy_model"],
      service_tier: args["service_tier"]
    ]
  end

  defp record_outcome(beat_ref, character_id, :committed) do
    App.dispatch(%RecordPacket{beat_ref: beat_ref, character_id: character_id})
  end

  defp record_outcome(beat_ref, character_id, {kind, reason})
       when kind in [:failed, :cancelled] do
    # Records the failure on the beat (§12) — it rolls up into BeatClosed.failed.
    App.dispatch(%RecordFailure{
      beat_ref: beat_ref,
      character_id: character_id,
      reason: inspect(reason)
    })
  end

  # Surface the terminal failure to the user with a retry (and, for a refusal, an
  # edit-and-resubmit) affordance. The stored args re-run this one packet
  # standalone (no chain), idempotent on packet_id.
  defp record_failure(args, character_id, {kind, reason}, messages) do
    refusal? = kind == :cancelled and match?({:refusal, _}, reason)

    Failures.record(
      worker: __MODULE__,
      scene_id: args["scene_id"],
      beat: args["beat"],
      subject: character_id,
      operation: :packet,
      kind: if(refusal?, do: :refusal, else: :transport),
      reason: inspect(reason),
      editable: refusal?,
      args: %{
        "scene_id" => args["scene_id"],
        "character_id" => character_id,
        "beat" => args["beat"],
        "packet_id" => BeatOps.packet_id(args["scene_id"], args["beat"], character_id),
        "messages" => messages,
        "provider" => args["provider"]
      }
    )
  end

  defp parse_control("continue"), do: :continue
  defp parse_control(:continue), do: :continue
  defp parse_control(_), do: :yield_to_user

  # ── Opts ─────────────────────────────────────────────────────────────────────

  defp gen_opts(args) do
    []
    |> maybe_put(:provider, BeatOps.resolve_provider(args["provider"]))
    |> maybe_put(:model, args["model"])
    # The campaign's heavy model for the refusal fallback (§9). Inert to the provider —
    # `retry_on_heavy_model` reads it, then strips it before the swap call.
    |> maybe_put(:heavy_model, args["heavy_model"])
    # DeepInfra scheduling tier (§9): a real body field, carried onto the refusal retry.
    |> maybe_put(:service_tier, args["service_tier"])
    # Character output-token budget from the campaign LLM settings (§9).
    |> maybe_put(:max_tokens, args["character_max_tokens"] || args["max_tokens"])
    |> maybe_put(:thinking, args["thinking"])
    # Bill the cast turn to the campaign owner (§B5); nil ids record nothing.
    |> maybe_put(:user_id, args["user_id"])
    |> maybe_put(:campaign_id, args["campaign_id"])
    # Debug trace attribution (scene-scoped LLM capture).
    |> maybe_put(:scene_id, args["scene_id"])
    |> maybe_put(:debug_subject, args["character_id"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
