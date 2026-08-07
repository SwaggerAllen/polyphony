defmodule Polyphony.Jobs.RunBeat do
  @moduledoc """
  The beat coordinator job — the Oban-driven half of the beat loop (§10).

  Per firing it makes the one Director judgment call (an LLM call, legitimately
  inside a job), applies the plan, and hands off to serial cast generation:

    1. `Director.decide/1` — Stage-1 arbitration + Stage-2 judgment.
    2. Author world events; apply membership-changing actions.
    3. If membership changed → **truncate**: enqueue the next `RunBeat` (re-decide
       against the new membership) unless the depth cap is hit.
    4. Else declare the turn order (unless the user set one), open the beat, and
       hand to `Director.BeatDriver.advance/3` — the async walk that enqueues the
       first slot, or pauses for a user-controlled/assisted one (§A1/§A2).
    5. An empty cast means yield — nothing is enqueued, and the loop rests until
       the user acts.

  The beat loop is durable and distributed: the walk decision is a pure function
  (`Director.BeatWalk`), and each generation is its own retried job, so serial
  ordering falls out of enqueue-next-on-completion. Tests drive it synchronously
  under `Oban.Testing.with_testing_mode(:inline, …)`.
  """
  use Oban.Worker, queue: :director, max_attempts: 3

  require Logger

  alias Polyphony.Scene.Cast
  alias Polyphony.{App, Broadcast, Content, Library}
  alias Polyphony.Content.CampaignConfig
  alias Polyphony.Costs.Attribution
  alias Polyphony.Director
  alias Polyphony.Director.{Auto, BeatDriver, BeatOps, BeatPolicy, Proposal, SceneBrief}
  alias Polyphony.Director.Commands.OpenBeat
  alias Polyphony.LLM.Settings

  @doc "Kick off (or resume) the beat loop for a scene."
  def enqueue(args) do
    args |> normalize() |> new() |> Oban.insert!()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    scene_id = args["scene_id"]

    # An auto run answers to its row, not to the job that happens to be queued. Paused,
    # finished, past its cap, closed by the Director, or emptied of everyone — all of it
    # is decided here, before a beat is paid for. See `Director.Auto`.
    case auto_gate(args, scene_id) do
      :stop -> :ok
      :go -> run(args, scene_id)
    end
  end

  defp run(args, scene_id) do
    args = args |> put_attribution(scene_id) |> put_content_register()
    # Per-campaign LLM tuning (§9), resolved fresh each beat so a campaign-screen edit
    # takes effect next beat. Character budget rides args to the cast jobs.
    settings = Settings.for_scene(scene_id)

    args =
      args
      |> Map.put("character_max_tokens", settings.character_max_tokens)
      # The campaign's chosen models ride to the cast jobs; nil ⇒ the provider's global
      # default. `model` is the workhorse both tiers run on; `heavy_model` the fallback.
      |> Map.put("character_model", settings.model)
      |> Map.put("heavy_model", settings.heavy_model)
      # DeepInfra scheduling tier (§9): priority jumps the queue during overload.
      |> Map.put("service_tier", settings.service_tier)

    beat = args["beat"]
    depth = args["depth"] || 0
    max_depth = args["max_depth"] || BeatPolicy.default_max_depth()

    members = BeatOps.members_now(scene_id, beat)

    # The Director is deciding the beat now — tell the play view so it can show it and
    # block input. `drive` and the cast walk take it from here (generating/idle).
    Broadcast.announce_progress(scene_id, :director, beat: beat)

    heavy = settings.heavy_model || heavy_model()

    case decide_with_fallback(decide_opts(args, scene_id, beat, members, settings), beat, heavy) do
      {:ok, resolved} ->
        resolved = cap_to_one_beat(resolved, args)
        # Counted here rather than at the end: this beat is now happening, and a crash
        # further down must not leave a run that can retry the same beat forever.
        if args["auto"], do: Auto.note_beat(scene_id, beat)
        BeatOps.author_world_events(resolved.world_events, scene_id, beat)
        BeatOps.author_introductions(Map.get(resolved, :introductions, []), scene_id, beat)

        drive(
          BeatOps.apply_membership_changes(resolved, scene_id, beat),
          resolved,
          args,
          scene_id,
          beat,
          depth,
          max_depth
        )

        :ok

      {:error, reason} ->
        # Director failure is the serious one (§12): retry with backoff, and if it
        # keeps failing fall back to yielding — never guess a cast.
        Logger.warning("director decision failed at beat #{beat}: #{inspect(reason)}")
        # Clear the busy indicator; an Oban retry re-announces :director on its next run.
        Broadcast.announce_progress(scene_id, :idle, beat: beat)
        {:error, reason}
    end
  end

  # The workhorse model sometimes returns an empty body or a spurious refusal
  # (§12; a known Qwen quirk) — which stalls Continue. Retry once on the heavy model,
  # the same model-swap the cast path uses for refusals. Rate-limit / transport
  # errors are NOT retried here (that's the separate 429-handling concern).
  defp decide_with_fallback(opts, beat, heavy) do
    case Director.decide(opts) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        if retry_on_heavy?(reason) && heavy do
          Logger.info("director #{inspect(reason)} at beat #{beat}; retrying on #{heavy}")
          Director.decide(Keyword.put(opts, :model, heavy))
        else
          {:error, reason}
        end
    end
  end

  # Empty/refusal: nothing to correct — a stronger model may simply comply.
  defp retry_on_heavy?({:director, :empty_response}), do: true
  defp retry_on_heavy?({:director, {:refusal, _}}), do: true
  # Malformed JSON that survived the Director's own self-correction: a stronger model
  # is more likely to emit valid, schema-shaped JSON.
  defp retry_on_heavy?({:director, :invalid_json}), do: true
  defp retry_on_heavy?(:invalid_decision), do: true
  defp retry_on_heavy?(_), do: false

  defp heavy_model, do: get_in(Application.get_env(:polyphony, :llm, []), [:models, :heavy])

  # A user-initiated Continue means "advance one beat, then hand back to me". When it
  # carries an explicit `yield_to_user` hint, honor it as authoritative over the model's
  # own `control`, so the loop doesn't self-chain further autonomous beats. Membership
  # truncation still runs — it re-decides the *same* exchange against a changed roster,
  # governed by the depth cap, not `control` — so a mid-beat exit is handled but the beat
  # doesn't spawn a fresh autonomous one. A future "Auto/Play" control omits the hint and
  # lets the Director pace up to the depth cap (see docs/roadmap.md).
  # `:go` unless this is an auto beat that shouldn't happen. A stop that came from one
  # of the run's three ends is recorded on the row and announced; a paused or absent run
  # is not an ending and says nothing.
  defp auto_gate(%{"auto" => true} = args, scene_id) do
    case Auto.check(scene_id, args["beat"] || 1) do
      :ok ->
        :go

      {:stop, nil} ->
        Broadcast.announce_progress(scene_id, :idle)
        :stop

      {:stop, reason} ->
        Logger.info("[auto] #{scene_id} stopped: #{Auto.reason_text(reason)}")
        Auto.finish(scene_id, reason)
        Broadcast.announce_progress(scene_id, :idle)
        :stop
    end
  end

  defp auto_gate(_args, _scene_id), do: :go

  defp cap_to_one_beat(resolved, args) do
    cond do
      # An auto run *is* the user for as long as it lasts, so the Director's hand-back
      # has nobody to hand back to. It ends on its own three rules (`Director.Auto`) —
      # honouring `yield_to_user` here would stop it after the first beat, every time,
      # which is the whole thing Continue already does.
      args["auto"] ->
        %{resolved | control: :continue}

      args["control_hint"] in ["yield_to_user", :yield_to_user] ->
        %{resolved | control: :yield_to_user}

      true ->
        resolved
    end
  end

  # ── Drive the outcome ────────────────────────────────────────────────────────

  defp drive(:changed, _resolved, args, scene_id, beat, depth, max_depth) do
    # Truncation (§10): re-decide against the new membership, subject to the cap.
    if depth + 1 < max_depth do
      enqueue(next_beat_args(args, scene_id, beat, depth))
    else
      Logger.info("beat #{beat}: truncated at depth cap; yielding")
      Broadcast.announce_progress(scene_id, :idle, beat: beat)
    end
  end

  defp drive(:unchanged, %{cast: []}, _args, scene_id, beat, _depth, _max_depth) do
    Logger.info("beat #{beat}: empty cast; yielding to user")
    Broadcast.announce_progress(scene_id, :idle, beat: beat)
  end

  defp drive(:unchanged, resolved, args, scene_id, beat, depth, max_depth) do
    # Declare the turn order (unless the user already set one), open the beat, and
    # hand off to the walk — it enqueues the first slot, or pauses for a
    # user-controlled/assisted one (§A1/§A2).
    # The Director casts from the omniscient brief, which renders display names
    # (§5.2 phase 2b-render) — so its picks come back as names. Resolve them to
    # character ids before they become the beat's declared turn order, because the
    # walk, packet ids and membership guards all key on ids.
    cast = Cast.for_scene(scene_id)
    members = BeatOps.members_now(scene_id, beat)

    {cast_ids, uncast} =
      resolved.cast
      |> Enum.map(&Cast.resolve_id(cast, &1.character_id))
      |> Enum.uniq()
      |> Enum.split_with(&(&1 in members))

    # A pick that resolves to nobody present is the Director inventing a character —
    # `resolve_id` has an identity fallback, so a hallucinated *name* comes back as
    # itself and would otherwise become a routing key (§5.2: never put a name where an
    # id belongs). It can only fail from there: their packets are rejected
    # `:not_a_member`, so they generate and print nothing. Introducing somebody is a
    # separate, author-approved act (§B7) — so route the pick to the introduction
    # queue and leave them out of this beat's order.
    propose_uncast(uncast, scene_id, beat)

    # The same filter over the *declared* order, because a user-set (or previously
    # recorded) order is read back verbatim and may name someone who has since left.
    order =
      scene_id |> BeatOps.declare_turn_order(beat, cast_ids) |> Enum.filter(&(&1 in members))

    if order == [] do
      Logger.info("beat #{beat}: nobody castable is present; yielding to user")
      Broadcast.announce_progress(scene_id, :idle, beat: beat)
    else
      open_and_walk(order, resolved, args, scene_id, beat, depth, max_depth)
    end
  end

  defp propose_uncast([], _scene_id, _beat), do: :ok

  defp propose_uncast(names, scene_id, beat) do
    Logger.info(
      "beat #{beat}: cast picks not present, queued as introductions: #{inspect(names)}"
    )

    BeatOps.author_introductions(
      Enum.map(names, &%{name: &1, reason: "the Director cast them into this scene"}),
      scene_id,
      beat
    )
  end

  defp open_and_walk(order, resolved, args, scene_id, beat, depth, max_depth) do
    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: BeatOps.beat_ref(scene_id, beat),
        scene_id: scene_id,
        beat: beat,
        cast: order
      })

    BeatDriver.advance(scene_id, beat,
      provider: args["provider"],
      depth: depth,
      max_depth: max_depth,
      control: resolved.control,
      auto: args["auto"] == true,
      user_id: args["user_id"],
      campaign_id: args["campaign_id"],
      character_max_tokens: args["character_max_tokens"],
      character_model: args["character_model"],
      heavy_model: args["heavy_model"],
      service_tier: args["service_tier"]
    )
  end

  # ── Args ─────────────────────────────────────────────────────────────────────

  defp decide_opts(args, scene_id, beat, members, settings) do
    [
      proposals: parse_proposals(args["proposals"]),
      options: parse_options(args["options"]),
      # The omniscient scene brief (§9): world + premise + cast + cross-scene
      # summaries (frozen at scene open) plus the full transcript and present roster.
      # cast_hint below is read only by the offline Mock; the real provider casts
      # from the brief. Both must know who is present.
      messages: SceneBrief.messages(scene_id, members, system: director_system_message(args)),
      scene_id: scene_id,
      beat: beat,
      provider: BeatOps.resolve_provider(args["provider"]),
      # Director thinking + token budget from the campaign's LLM settings (§9). With
      # thinking on, the reasoning trace shares the budget, so keep the cap generous.
      thinking: settings.director_thinking,
      max_tokens: settings.director_max_tokens,
      # The campaign's workhorse model (nil ⇒ the provider's global default).
      model: settings.model,
      # DeepInfra scheduling tier for the Director call (nil ⇒ standard).
      service_tier: settings.service_tier,
      cast_hint: members,
      control_hint: parse_control(args["control_hint"]),
      # Bill the Director's judgment to the campaign owner (§B5); nil ids record nothing.
      user_id: args["user_id"],
      campaign_id: args["campaign_id"],
      usage_kind: "director",
      debug_subject: "director"
    ]
  end

  # Attribute autonomous spend (the Director's decision + the cast turns it drives) to
  # the campaign owner (§B5). Resolved once from the scene and carried on args, so
  # self-chained beats and cast jobs bill the same owner without re-resolving.
  defp put_attribution(args, scene_id) do
    if Map.has_key?(args, "user_id") or Map.has_key?(args, "campaign_id") do
      args
    else
      attr = Attribution.for_scene(scene_id)
      Map.merge(args, %{"user_id" => attr.user_id, "campaign_id" => attr.campaign_id})
    end
  end

  # The Director is told the effective content register too (§A5) — governance is a
  # context-assembly input for the Director, same as for the cast. `content_register`
  # rides the args (category strings), computed once at scene open by the caller.
  @doc false
  def director_system_message(args) do
    base = "You are the Director. Cast and pace the scene."

    case Polyphony.Content.render_register(Polyphony.Content.cast_categories(register_arg(args))) do
      nil -> base
      line -> base <> "\n\n" <> line
    end
  end

  defp register_arg(args), do: args["content_register"] || []

  # Resolve the effective content register once (per beat chain) from the campaign's
  # content config (§A5), so the Director is told the same ceiling the cast context was
  # capped by. Rides args as category strings and carries forward to self-chained beats.
  # `campaign_id` is already on args (put_attribution); nil-safe → empty register.
  defp put_content_register(args) do
    if Map.has_key?(args, "content_register") do
      args
    else
      register =
        args["campaign_id"]
        |> campaign_content_config()
        |> Content.register(attested: true)
        |> Enum.map(&to_string/1)

      Map.put(args, "content_register", register)
    end
  end

  defp campaign_content_config(nil), do: %CampaignConfig{}

  defp campaign_content_config(campaign_id) do
    case Library.get(campaign_id) do
      %{} = entry -> CampaignConfig.from_payload(Library.payload(entry))
      _ -> %CampaignConfig{}
    end
  rescue
    _ -> %CampaignConfig{}
  end

  defp next_beat_args(args, scene_id, beat, depth) do
    args
    |> Map.merge(%{"scene_id" => scene_id, "beat" => beat + 1, "depth" => depth + 1})
    |> Map.drop([
      "chain",
      "beat_ref",
      "character_id",
      "packet_id",
      "remaining",
      "pacing_note",
      "control",
      "messages"
    ])
  end

  defp normalize(args) do
    args
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("beat", 1)
    |> Map.put_new("depth", 0)
  end

  defp parse_options(nil), do: %{exits: [], entities: []}

  defp parse_options(opts),
    do: %{exits: Map.get(opts, "exits", []), entities: Map.get(opts, "entities", [])}

  defp parse_proposals(nil), do: []

  defp parse_proposals(list) do
    Enum.map(list, fn p ->
      %Proposal{
        actor_id: p["actor_id"],
        type: parse_type(p["type"]),
        target: p["target"],
        detail: p["detail"]
      }
    end)
  end

  defp parse_type("exit"), do: :exit
  defp parse_type("interact"), do: :interact
  defp parse_type(_), do: :novel

  defp parse_control("continue"), do: :continue
  defp parse_control(:continue), do: :continue
  defp parse_control(_), do: :yield_to_user
end
