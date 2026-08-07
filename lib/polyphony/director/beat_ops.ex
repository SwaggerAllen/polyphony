defmodule Polyphony.Director.BeatOps do
  @moduledoc """
  Shared, mostly-pure helpers for driving a beat — used by the Oban jobs
  (`RunBeat`, `GeneratePacket`) so the beat loop's plumbing lives in one place.

  Deterministic ids (`beat_ref/2`, `packet_id/3`), membership read from the
  stream, per-character message assembly from the cached context, and the two
  side-effecting plan applications (world events, membership changes) that run
  before the cast generates.
  """

  alias Polyphony.{App, Context}
  alias PolyphonyCore.{MembershipSet, Packets}
  alias Polyphony.Context.{Rebuild, Store}
  alias Polyphony.Commands.{RecordWorldEvent, ExitCharacter, CloseScene, ProposeIntroduction}
  alias Polyphony.Director.Proposal

  @typedoc "An event-store stream id — a scene, standing in for a branch."
  @type scene_id :: String.t()
  @typedoc "A character's **library entry id**, never their display name (§5.2)."
  @type character_id :: String.t()
  @typedoc "The integer grouping label. Not an ordering key — the store's sequence is."
  @type beat :: integer()
  @typedoc "A chat message as the provider adapters take one."
  @type message :: %{role: String.t(), content: String.t()}

  @doc "The beat aggregate's stream id (distinct from the integer scene beat)."
  @spec beat_ref(scene_id(), beat()) :: String.t()
  def beat_ref(scene_id, beat), do: "#{scene_id}-b#{beat}"

  @doc "Deterministic packet id `(scene, beat, character)` for idempotency (§12)."
  @spec packet_id(scene_id(), beat(), character_id()) :: String.t()
  def packet_id(scene_id, beat, character_id), do: "#{scene_id}-#{beat}-#{character_id}"

  @doc """
  The packet id for re-roll attempt `n` of `(scene, beat, character)` (`n >= 1`).
  The base attempt (`packet_id/3`) is unsuffixed; each re-roll adds `-r<n>`, so
  every attempt is a distinct, addressable packet (§7, §12).
  """
  @spec reroll_packet_id(scene_id(), beat(), character_id(), pos_integer()) :: String.t()
  def reroll_packet_id(scene_id, beat, character_id, attempt) when attempt >= 1,
    do: "#{packet_id(scene_id, beat, character_id)}-r#{attempt}"

  @doc """
  The next re-roll attempt index for `(scene, beat, character)` — one past the
  highest attempt already seen, so it stays collision-free even when earlier
  attempts are absent (a fork copies only the canonical take, not superseded
  ones, so counting would re-use a live id). `1` when only the base attempt
  exists; `0` when the packet doesn't exist yet.
  """
  @spec next_attempt([struct() | map()], scene_id(), beat(), character_id()) :: non_neg_integer()
  def next_attempt(events, scene_id, beat, character_id) do
    base = packet_id(scene_id, beat, character_id)

    indices =
      for e <- events,
          id = Map.get(e, :packet_id),
          is_binary(id),
          attempt_of?(id, base),
          do: attempt_index(id, base)

    case indices do
      [] -> 0
      xs -> highest(xs, 0) + 1
    end
  end

  # `Enum.max/1` returns the element type, which Dialyzer widens to `number()`, and
  # `Enum.reduce/3`'s accumulator is `any()` — either way an attempt index that can
  # only ever be an integer reads as possibly-float. Spelled out so the type is
  # provable, because the result becomes part of a packet id.
  @spec highest([non_neg_integer()], non_neg_integer()) :: non_neg_integer()
  defp highest([], acc), do: acc
  defp highest([n | rest], acc), do: highest(rest, max(n, acc))

  defp attempt_of?(id, base), do: id == base or String.starts_with?(id, base <> "-r")

  defp attempt_index(id, base) do
    if id == base do
      0
    else
      case Integer.parse(String.replace_prefix(id, base <> "-r", "")) do
        {n, ""} -> n
        _ -> 0
      end
    end
  end

  @doc "All events on a scene's stream (empty if the stream doesn't exist yet)."
  @spec stored_events(scene_id()) :: [struct()]
  def stored_events(scene_id) do
    App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end

  @doc "The canonical view of a scene's stream — re-rolled packets filtered out (§7)."
  @spec canonical_events(scene_id()) :: [struct()]
  def canonical_events(scene_id), do: scene_id |> stored_events() |> Packets.canonical()

  @doc "Events on a beat's own aggregate stream (`beat_ref`), empty if it hasn't opened."
  @spec beat_events(scene_id(), beat()) :: [struct()]
  def beat_events(scene_id, beat) do
    App |> Commanded.EventStore.stream_forward(beat_ref(scene_id, beat)) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end

  @doc """
  The turn order for a beat (§A1): the user's declaration if one exists, otherwise
  the given default cast — which is recorded as a `TurnOrderDeclared` so re-roll and
  the walk read a single source of truth. Returns the ordered `character_id`s.
  """
  @spec declare_turn_order(scene_id(), beat(), [character_id()]) :: [character_id()]
  def declare_turn_order(scene_id, beat, default_cast_ids) do
    events = canonical_events(scene_id)

    case PolyphonyCore.TurnOrder.for_beat(events, beat) do
      nil ->
        :ok =
          App.dispatch(%Polyphony.Commands.DeclareTurnOrder{
            scene_id: scene_id,
            beat: beat,
            order: default_cast_ids
          })

        default_cast_ids

      declared ->
        declared
    end
  end

  @doc "Character ids present in the scene at `beat`, derived from the log."
  @spec members_now(scene_id(), beat()) :: [character_id()]
  def members_now(scene_id, beat) do
    scene_id
    |> stored_events()
    |> MembershipSet.from_events()
    |> MembershipSet.members_at(scene_id, beat)
  end

  @doc """
  Build a cast member's messages: the cached frozen prefix plus the freshly
  re-read live history (so serial conditioning holds), plus any pacing note.
  Falls back to a minimal seed if no context is cached.
  """
  @spec messages_for(scene_id(), beat(), character_id(), String.t() | nil) :: [message()]
  def messages_for(scene_id, beat, character_id, pacing_note \\ nil) do
    # Condition on the canonical log so a re-rolled packet never re-enters a
    # later cast member's context (§7).
    live = canonical_events(scene_id)
    members = members_now(scene_id, beat)

    base =
      case Store.fetch(scene_id, character_id) do
        {:ok, ctx} ->
          Context.to_messages(ctx, live_events: live, members: members)

        :error ->
          # Cache cold — e.g. a node restart wiped ETS mid-scene. Rebuild the frozen
          # context from durable data (sheet + premise + world from the campaign,
          # long-tail from pgvector) and re-cache, so the turn conditions on the real
          # character instead of a bare stub. Only the truly-unresolvable case (no
          # campaign sheet) drops to the fallback — which still states the schema.
          case Rebuild.for_character(scene_id, character_id) do
            {:ok, ctx} ->
              Store.put(scene_id, character_id, ctx)
              Context.to_messages(ctx, live_events: live, members: members)

            :error ->
              fallback_messages(character_id)
          end
      end

    base ++ pacing(pacing_note)
  end

  # Last resort (no resolvable sheet): still spell out the TurnPacket schema, so the
  # model can't free-form a foreign JSON shape (the `schema_invalid` failure mode a
  # bare "respond with a TurnPacket" prompt produced).
  defp fallback_messages(character_id) do
    [
      %{role: "system", content: "You are #{character_id}."},
      %{role: "user", content: Context.default_turn_instruction()}
    ]
  end

  defp pacing(note) when is_binary(note) and note != "",
    do: [%{role: "user", content: "Direction: #{note}"}]

  defp pacing(_), do: []

  @doc "Dispatch the Director's authored world events onto the scene log."
  @spec author_world_events(Enumerable.t(), scene_id(), beat()) :: :ok
  def author_world_events(world_events, scene_id, beat) do
    Enum.each(world_events, fn we ->
      App.dispatch(%RecordWorldEvent{
        scene_id: Map.get(we, :scene_id) || scene_id,
        beat: beat,
        content: we.content
      })
    end)
  end

  @doc """
  Dispatch the Director's character-introduction proposals onto the scene log. These
  are omniscient-only queue signals (§B7) — they do NOT change membership, so they
  never trigger truncation; the author admits them from the play view.
  """
  @spec author_introductions(Enumerable.t() | nil, scene_id(), beat()) :: :ok
  def author_introductions(introductions, scene_id, beat) do
    Enum.each(introductions || [], fn intro ->
      App.dispatch(%ProposeIntroduction{
        scene_id: scene_id,
        beat: beat,
        name: intro.name,
        reason: Map.get(intro, :reason)
      })
    end)
  end

  @doc """
  Apply membership-changing parts of the plan (accepted exits, close/move scene
  actions). Returns `:changed` or `:unchanged` — `:changed` triggers beat
  truncation (§10).
  """
  @spec apply_membership_changes(map(), scene_id(), beat()) :: :changed | :unchanged
  def apply_membership_changes(resolved, scene_id, beat) do
    exits = Enum.filter(resolved.accepted, &match?(%Proposal{type: :exit}, &1))
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

  @doc "Resolve an optional `\"provider\"` arg (module name string) to a module."
  @spec resolve_provider(module() | String.t() | nil) :: module() | nil
  def resolve_provider(nil), do: nil
  def resolve_provider(mod) when is_atom(mod), do: mod

  def resolve_provider(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
