defmodule Polyphony.Director.Runner do
  @moduledoc """
  Drives the beat loop (§10): the orchestration that composes the tested Director
  pieces into a running scene.

  Per beat:

    1. `Director.decide/1` — Stage-1 arbitration + one judgment call.
    2. Apply the plan: author world events, apply membership-changing actions.
    3. If membership changed, **truncate** — do not generate the cast; the beat is
       re-decided against the new membership (§10 beat truncation).
    4. Otherwise open the beat, then generate the cast **serially** — each member's
       context is rebuilt from the freshly re-read stream, so B conditions on A's
       just-committed packet (§10 serial generation). Commit each, record it on the
       beat; on failure, record the failure (the beat is not atomic, §12).
    5. Close the beat (`BeatClosed{completed, failed}`), then consult
       `BeatPolicy` to continue, truncate-and-re-decide, or yield to the user.

  This is a plain orchestrator, not a Commanded process manager, so it may call
  generation (rule 1 forbids that only inside aggregates/process managers). In
  production each generation step would be an enqueued `GeneratePacket` job with
  the runner reacting to `BeatClosed`; here it runs inline and serially so the
  loop is exercisable end-to-end with the Mock provider.
  """

  require Logger

  alias Polyphony.{App, Context, Generation, MembershipSet}
  alias Polyphony.Commands.{CommitPacket, RecordWorldEvent, ExitCharacter, CloseScene}
  alias Polyphony.Director
  alias Polyphony.Director.{BeatPolicy, Proposal}
  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, CloseBeat}

  @doc """
  Run beats until the Director yields or the depth cap is hit.

  Required opts: `:scene_id`, `:contexts` (`%{char_id => SceneContext}`). Optional:
  `:options` (topology), `:provider`, `:proposals`, `:control_hint`, `:max_depth`,
  `:start_beat`.
  """
  @spec run(keyword() | map()) :: {:ok, [map()]} | {:error, term()}
  def run(opts) do
    opts = Map.new(opts)
    do_run(opts, Map.get(opts, :start_beat, 1), 0, [])
  end

  defp do_run(opts, beat, depth, acc) do
    case run_beat(Map.merge(opts, %{beat: beat, depth: depth})) do
      {:ok, outcome} ->
        acc = [outcome | acc]

        case outcome.next do
          :yield_to_user -> {:ok, Enum.reverse(acc)}
          _ -> do_run(opts, beat + 1, depth + 1, acc)
        end

      {:error, _} = err ->
        err
    end
  end

  @doc "Run a single beat and return its outcome (see `run/1`)."
  @spec run_beat(map()) :: {:ok, map()} | {:error, term()}
  def run_beat(opts) do
    scene_id = Map.fetch!(opts, :scene_id)
    beat = Map.fetch!(opts, :beat)
    depth = Map.get(opts, :depth, 0)
    provider = Map.get(opts, :provider)
    max_depth = Map.get(opts, :max_depth, BeatPolicy.default_max_depth())

    members = members_now(scene_id, beat)

    with {:ok, resolved} <- decide(opts, scene_id, beat, provider, members) do
      author_world_events(resolved.world_events, scene_id, beat)

      case apply_membership_changes(resolved, scene_id, beat) do
        :changed ->
          # Truncate (§10): remaining cast do not generate; re-decide next beat.
          {:ok, outcome(beat, resolved, [], [], true, depth, max_depth)}

        :unchanged ->
          {committed, failed} = generate_cast(resolved.cast, scene_id, beat, provider, opts)
          {:ok, outcome(beat, resolved, committed, failed, false, depth, max_depth)}
      end
    end
  end

  # ── Decision ────────────────────────────────────────────────────────────────

  defp decide(opts, scene_id, beat, provider, members) do
    Director.decide(
      proposals: Map.get(opts, :proposals, []),
      options: Map.get(opts, :options, %{exits: [], entities: []}),
      messages: [%{role: "system", content: "You are the Director. Cast and pace the scene."}],
      scene_id: scene_id,
      beat: beat,
      provider: provider,
      cast_hint: members,
      control_hint: Map.get(opts, :control_hint, :yield_to_user)
    )
  end

  # ── Serial cast generation (§10) ─────────────────────────────────────────────

  defp generate_cast([], _scene_id, _beat, _provider, _opts), do: {[], []}

  defp generate_cast(cast, scene_id, beat, provider, opts) do
    cast_ids = Enum.map(cast, & &1.character_id)

    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: beat_ref(scene_id, beat),
        scene_id: scene_id,
        beat: beat,
        cast: cast_ids
      })

    {committed, failed} =
      Enum.reduce(cast, {[], []}, fn member, {c, f} ->
        case generate_one(member, scene_id, beat, provider, opts) do
          {:ok, id} -> {[id | c], f}
          {:error, id, reason} -> {c, [{id, reason} | f]}
        end
      end)

    :ok = App.dispatch(%CloseBeat{beat_ref: beat_ref(scene_id, beat)})
    {Enum.reverse(committed), Enum.reverse(failed)}
  end

  defp generate_one(member, scene_id, beat, provider, opts) do
    id = member.character_id
    ctx = opts |> Map.fetch!(:contexts) |> Map.fetch!(id)

    # Re-read the stream so this member conditions on packets already committed
    # this beat — the whole point of serial generation.
    live = stored_events(scene_id)
    members = members_now(scene_id, beat)

    messages = Context.to_messages(ctx, live_events: live, members: members) ++ pacing(member)

    gen_opts = provider_opts(provider)

    case Generation.generate(messages, gen_opts) do
      {:ok, packet} ->
        :ok =
          App.dispatch(%CommitPacket{
            scene_id: scene_id,
            character_id: id,
            beat: beat,
            packet_id: packet_id(scene_id, beat, id),
            packet: packet
          })

        :ok = App.dispatch(%RecordPacket{beat_ref: beat_ref(scene_id, beat), character_id: id})
        {:ok, id}

      {:error, reason} ->
        Logger.info("packet failed for #{id}@#{beat}: #{inspect(reason)}")

        :ok =
          App.dispatch(%RecordFailure{
            beat_ref: beat_ref(scene_id, beat),
            character_id: id,
            reason: inspect(reason)
          })

        {:error, id, reason}
    end
  end

  # ── Membership-changing actions → truncation ─────────────────────────────────

  defp apply_membership_changes(resolved, scene_id, beat) do
    exits =
      resolved.accepted
      |> Enum.filter(&match?(%Proposal{type: :exit}, &1))

    closes = Enum.filter(resolved.scene_actions, &(&1.action in [:close, :move]))

    Enum.each(exits, fn %Proposal{actor_id: who} ->
      App.dispatch(%ExitCharacter{scene_id: scene_id, character_id: who, beat: beat})
    end)

    Enum.each(closes, fn
      %{action: :close} ->
        App.dispatch(%CloseScene{scene_id: scene_id, closed_beat: beat})

      %{action: :move, character_id: who} ->
        App.dispatch(%ExitCharacter{scene_id: scene_id, character_id: who, beat: beat})
    end)

    if exits == [] and closes == [], do: :unchanged, else: :changed
  end

  defp author_world_events(world_events, scene_id, beat) do
    Enum.each(world_events, fn we ->
      App.dispatch(%RecordWorldEvent{
        scene_id: we.scene_id || scene_id,
        beat: beat,
        content: we.content
      })
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp outcome(beat, resolved, committed, failed, membership_changed, depth, max_depth) do
    next =
      BeatPolicy.next(%{
        depth: depth,
        control: resolved.control,
        membership_changed: membership_changed,
        max_depth: max_depth
      })

    %{
      beat: beat,
      decision: resolved,
      committed: committed,
      failed: failed,
      membership_changed: membership_changed,
      next: next
    }
  end

  defp members_now(scene_id, beat) do
    scene_id
    |> stored_events()
    |> MembershipSet.from_events()
    |> MembershipSet.members_at(scene_id, beat)
  end

  defp stored_events(scene_id) do
    App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end

  defp provider_opts(nil), do: []
  defp provider_opts(provider), do: [provider: provider]

  defp pacing(%{pacing_note: note}) when is_binary(note) and note != "",
    do: [%{role: "user", content: "Direction: #{note}"}]

  defp pacing(_), do: []

  defp packet_id(scene_id, beat, char_id), do: "#{scene_id}-#{beat}-#{char_id}"
  defp beat_ref(scene_id, beat), do: "#{scene_id}-b#{beat}"
end
