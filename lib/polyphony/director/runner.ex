defmodule Polyphony.Director.Runner do
  @moduledoc """
  Drives the beat loop (§10): the orchestration that composes the tested Director
  pieces into a running scene.

  Per beat:

    1. `Director.decide/1` — Stage-1 arbitration + one judgment call.
    2. Apply the plan: author world events, apply membership-changing actions.
    3. If membership changed, **truncate** — do not generate the cast; the beat is
       re-decided against the new membership (§10 beat truncation).
    4. Otherwise declare the turn order (unless the user already did), open the
       beat, and **walk the cast in that order** (§A1). Each slot is either
       autonomous — generate serially, each member's context rebuilt from the
       freshly re-read stream so B conditions on A's just-committed packet (§10) —
       or **user-controlled**, where the walk yields (`{:awaiting_user, …}`) and the
       caller resumes with `submit_user_turn/5` or `pass_turn/4`. A beat can yield
       more than once. The declared order is authoritative, so a user reorder or
       removal is honored.
    5. Close the beat once every slot is terminal — committed, failed, or passed
       (`BeatClosed{completed, failed, passed}`) — then consult `BeatPolicy` to
       continue, truncate-and-re-decide, or yield to the user.

  This is a plain orchestrator, not a Commanded process manager, so it may call
  generation (rule 1 forbids that only inside aggregates/process managers). In
  production each generation step would be an enqueued `GeneratePacket` job with
  the runner reacting to `BeatClosed`; here it runs inline and serially so the
  loop is exercisable end-to-end with the Mock provider.
  """

  require Logger

  alias Polyphony.{App, Context, Drafts, Generation, MembershipSet, Packets, TurnOrder}

  alias Polyphony.Commands.{
    CommitPacket,
    DeclareTurnOrder,
    RecordWorldEvent,
    ExitCharacter,
    CloseScene
  }

  alias Polyphony.Director
  alias Polyphony.Director.{BeatPolicy, Proposal}
  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, RecordPass, CloseBeat}
  alias Polyphony.Events.{PacketPassed, PacketFailed}

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

      # A user-controlled (§A1) or assisted (§A2) slot paused the beat: the loop
      # stops here and the caller resumes via submit_user_turn/pass_turn or
      # accept_draft/discard_draft.
      {:awaiting_user, info} ->
        {:awaiting_user, info, Enum.reverse(acc)}

      {:awaiting_draft, info} ->
        {:awaiting_draft, info, Enum.reverse(acc)}

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
          case walk_beat(scene_id, beat, resolved, provider, opts) do
            {:closed, sets} ->
              {:ok, outcome(beat, resolved, sets.committed, sets.failed, false, depth, max_depth)}

            {:awaiting_user, character_id} ->
              {:awaiting_user,
               %{scene_id: scene_id, beat: beat, character_id: character_id, decision: resolved}}

            {:awaiting_draft, info} ->
              {:awaiting_draft, Map.put(info, :decision, resolved)}
          end
      end
    end
  end

  @doc """
  Resume a beat that yielded, committing the user's packet for `character_id`, then
  walking the rest of the cast (§A1). Returns `{:ok, sets}` when the beat closes or
  `{:awaiting_user, info}` if a later slot is also user-controlled. `opts` needs the
  same `:contexts`/`:provider` as `run_beat` (subsequent autonomous slots generate).
  """
  def submit_user_turn(scene_id, beat, character_id, packet, opts) do
    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene_id,
        character_id: character_id,
        beat: beat,
        packet_id: packet_id(scene_id, beat, character_id),
        packet: packet
      })

    :ok =
      App.dispatch(%RecordPacket{beat_ref: beat_ref(scene_id, beat), character_id: character_id})

    resume(scene_id, beat, opts)
  end

  @doc "Resume a yielded beat with the user skipping `character_id`'s turn (§A1)."
  def pass_turn(scene_id, beat, character_id, opts) do
    :ok =
      App.dispatch(%RecordPass{beat_ref: beat_ref(scene_id, beat), character_id: character_id})

    resume(scene_id, beat, opts)
  end

  @doc """
  Accept the pending draft for an **assisted** slot (§A2): commit it, then walk the
  rest of the beat. Edit first with `Polyphony.Drafts.edit/3` for accept-and-edit.
  """
  def accept_draft(draft_id, opts) do
    opts = Map.new(opts)

    case Drafts.accept(draft_id, repo: Map.get(opts, :repo, Polyphony.Repo)) do
      {:ok, %{scene_id: scene_id, beat: beat, character_id: character_id}} ->
        :ok =
          App.dispatch(%RecordPacket{
            beat_ref: beat_ref(scene_id, beat),
            character_id: character_id
          })

        resume(scene_id, beat, opts)

      error ->
        error
    end
  end

  @doc "Discard the pending draft for an assisted slot — the character passes this beat (§A2)."
  def discard_draft(draft_id, opts) do
    opts = Map.new(opts)
    repo = Map.get(opts, :repo, Polyphony.Repo)

    case Drafts.get(draft_id, repo: repo) do
      nil ->
        {:error, :not_found}

      row ->
        Drafts.discard(draft_id, repo: repo)

        :ok =
          App.dispatch(%RecordPass{
            beat_ref: beat_ref(row.scene_id, row.beat),
            character_id: row.character_id
          })

        resume(row.scene_id, row.beat, opts)
    end
  end

  defp resume(scene_id, beat, opts) do
    opts = Map.new(opts)

    case advance(scene_id, beat, Map.get(opts, :provider), %{}, opts) do
      {:closed, sets} ->
        {:ok, Map.put(sets, :beat, beat)}

      {:awaiting_user, char} ->
        {:awaiting_user, %{scene_id: scene_id, beat: beat, character_id: char}}

      {:awaiting_draft, info} ->
        {:awaiting_draft, info}
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

  # ── Serial cast walk with yields (§10, §A1) ──────────────────────────────────

  # Declare the turn order (unless the user already did), open the beat, then walk.
  defp walk_beat(_scene_id, _beat, %{cast: []}, _provider, _opts),
    do: {:closed, %{committed: [], failed: [], passed: []}}

  defp walk_beat(scene_id, beat, resolved, provider, opts) do
    cast_ids = Enum.map(resolved.cast, & &1.character_id)
    order = declared_or_default(scene_id, beat, cast_ids)
    pacing = Map.new(resolved.cast, &{&1.character_id, Map.get(&1, :pacing_note)})

    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: beat_ref(scene_id, beat),
        scene_id: scene_id,
        beat: beat,
        cast: order
      })

    advance(scene_id, beat, provider, pacing, Map.new(opts))
  end

  # Walk the declared order: generate autonomous slots serially; stop and yield at
  # a user-controlled one; close when every slot is terminal (committed/failed/
  # passed). Re-derives progress from the log each step, so it resumes after a yield
  # without holding state.
  defp advance(scene_id, beat, provider, pacing, opts) do
    events = scene_id |> stored_events() |> Packets.canonical()
    order = TurnOrder.for_beat(events, beat) || []
    done = terminal_chars(scene_id, beat, events)

    case Enum.find(order, &(&1 not in done)) do
      nil ->
        :ok = App.dispatch(%CloseBeat{beat_ref: beat_ref(scene_id, beat)})
        {:closed, terminal_sets(scene_id, beat, events, order)}

      character_id ->
        case TurnOrder.control_mode(events, character_id) do
          "user_controlled" ->
            {:awaiting_user, character_id}

          "assisted" ->
            # Generate, but present it as a draft to confirm rather than committing
            # (§A2). A failed generation just records the failure and the walk moves
            # on (the beat is not atomic, §12).
            case generate_draft(
                   character_id,
                   Map.get(pacing, character_id),
                   scene_id,
                   beat,
                   provider,
                   opts
                 ) do
              {:ok, draft} ->
                {:awaiting_draft,
                 %{scene_id: scene_id, beat: beat, character_id: character_id, draft_id: draft.id}}

              :error ->
                advance(scene_id, beat, provider, pacing, opts)
            end

          _autonomous ->
            generate_one(
              character_id,
              Map.get(pacing, character_id),
              scene_id,
              beat,
              provider,
              opts
            )

            advance(scene_id, beat, provider, pacing, opts)
        end
    end
  end

  defp generate_one(id, pacing_note, scene_id, beat, provider, opts) do
    ctx = opts |> Map.fetch!(:contexts) |> Map.fetch!(id)

    # Re-read the stream so this member conditions on packets already committed
    # this beat — the point of serial generation. Canonical view only, so a
    # re-rolled packet never leaks back into a later cast member's context (§7).
    live = scene_id |> stored_events() |> Packets.canonical()
    members = members_now(scene_id, beat)

    messages =
      Context.to_messages(ctx, live_events: live, members: members) ++ pacing(pacing_note)

    case Generation.generate(messages, provider_opts(provider)) do
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

      {:error, reason} ->
        Logger.info("packet failed for #{id}@#{beat}: #{inspect(reason)}")

        :ok =
          App.dispatch(%RecordFailure{
            beat_ref: beat_ref(scene_id, beat),
            character_id: id,
            reason: inspect(reason)
          })
    end
  end

  # Assisted (§A2): generate the same way, but store the result as a pending draft
  # instead of committing. `{:ok, draft}` to yield for confirmation, `:error` (with
  # the failure recorded) so the walk continues.
  defp generate_draft(id, pacing_note, scene_id, beat, provider, opts) do
    ctx = opts |> Map.fetch!(:contexts) |> Map.fetch!(id)
    live = scene_id |> stored_events() |> Packets.canonical()
    members = members_now(scene_id, beat)

    messages =
      Context.to_messages(ctx, live_events: live, members: members) ++ pacing(pacing_note)

    case Generation.generate(messages, provider_opts(provider)) do
      {:ok, packet} ->
        {:ok,
         Drafts.draft(scene_id, id, beat, packet, source: "assisted", repo: draft_repo(opts))}

      {:error, reason} ->
        Logger.info("assisted draft failed for #{id}@#{beat}: #{inspect(reason)}")

        :ok =
          App.dispatch(%RecordFailure{
            beat_ref: beat_ref(scene_id, beat),
            character_id: id,
            reason: inspect(reason)
          })

        :error
    end
  end

  defp draft_repo(opts), do: Map.get(opts, :repo, Polyphony.Repo)

  # A cast member is terminal once committed (canonical packet), failed, or passed.
  defp terminal_chars(scene_id, beat, events) do
    committed = events |> Packets.beat_packets(beat) |> MapSet.new(fn {char, _} -> char end)
    {passed, failed} = beat_terminals(scene_id, beat)
    committed |> MapSet.union(passed) |> MapSet.union(failed)
  end

  defp terminal_sets(scene_id, beat, events, order) do
    committed_set = events |> Packets.beat_packets(beat) |> MapSet.new(fn {char, _} -> char end)
    committed = Enum.filter(order, &MapSet.member?(committed_set, &1))
    beat_events = beat_events(scene_id, beat)

    %{
      committed: committed,
      failed: for(%PacketFailed{character_id: c, reason: r} <- beat_events, do: {c, r}),
      passed: for(%PacketPassed{character_id: c} <- beat_events, do: c)
    }
  end

  defp beat_terminals(scene_id, beat) do
    beat_events = beat_events(scene_id, beat)
    passed = for %PacketPassed{character_id: c} <- beat_events, into: MapSet.new(), do: c
    failed = for %PacketFailed{character_id: c} <- beat_events, into: MapSet.new(), do: c
    {passed, failed}
  end

  defp beat_events(scene_id, beat) do
    App |> Commanded.EventStore.stream_forward(beat_ref(scene_id, beat)) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end

  defp declared_or_default(scene_id, beat, cast_ids) do
    events = scene_id |> stored_events() |> Packets.canonical()

    case TurnOrder.for_beat(events, beat) do
      nil ->
        :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene_id, beat: beat, order: cast_ids})
        cast_ids

      declared ->
        declared
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

  defp pacing(note) when is_binary(note) and note != "",
    do: [%{role: "user", content: "Direction: #{note}"}]

  defp pacing(_), do: []

  defp packet_id(scene_id, beat, char_id), do: "#{scene_id}-#{beat}-#{char_id}"
  defp beat_ref(scene_id, beat), do: "#{scene_id}-b#{beat}"
end
