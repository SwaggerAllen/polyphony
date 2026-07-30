defmodule Polyphony.Broadcast do
  @moduledoc """
  The client-streaming contract (§13), as a pure fan-out.

  A committed event is published to **per-viewer topics**, and — critically — a
  viewer only receives an event that is visible to them. The fan-out routes every
  event through the *same* `Polyphony.Visibility.visible_to?/3` used to build
  character contexts, so the transport can never leak more than the projection
  (§13 "never hardcode omniscience into the transport"). The omniscient user and
  a second human playing a character are just different viewer values.

  This module is pure: `fan_out/5` decides *who sees what* and shapes the message;
  the `Publisher` event handler does the actual `Phoenix.PubSub` broadcast, and a
  reconnecting client calls `replay/4` for cursor catch-up. Both use this core, so
  the live tail and the replay are filtered identically.

  ## Scope

  v1 handles **scene-scoped events** → `event.committed` messages, the essential
  LiveView feed. Beat framing (`beat.opened/closed`), `generation.failed`, and
  `awaiting.user` are emitted by the beat loop and layer on once beat events carry
  their scene id.
  """

  alias Polyphony.{Visibility, Packets}

  alias Polyphony.Events.{
    ThoughtOccurred,
    PrivateStateReported,
    SpeechUttered,
    ActionTaken,
    DemeanorReported,
    CharacterEntered,
    CharacterExited,
    BeatOpened,
    BeatClosed,
    PacketSuperseded
  }

  @type viewer :: :omniscient | {:character, term()}

  @doc "The PubSub topic for a `(scene, viewer)` pair."
  @spec topic(term(), viewer()) :: String.t()
  def topic(scene_id, :omniscient), do: "scene:#{scene_id}:omniscient"
  def topic(scene_id, {:character, id}), do: "scene:#{scene_id}:character:#{id}"

  # ── Beat-loop progress (not fiction — a scene-wide activity signal) ─────────────
  #
  # Which step of the beat loop is running right now (the Director deciding, a named
  # character generating, waiting on the user, or idle). Every viewer subscribes so the
  # play view can show *what's happening when* and block input while a beat runs — this
  # is the reliable "done" signal the transcript stream never carried (a beat closes on
  # the beat_ref stream, which the per-viewer transport doesn't publish).

  @type phase :: :director | :generating | :awaiting_user | :idle

  @doc "The scene-wide progress topic — viewer-independent (it's activity, not content)."
  @spec progress_topic(term()) :: String.t()
  def progress_topic(scene_id), do: "scene:#{scene_id}:progress"

  @doc "Announce the current beat-loop phase to every viewer of the scene (best-effort)."
  @spec announce_progress(term(), phase(), keyword()) :: :ok
  def announce_progress(scene_id, phase, opts \\ []) do
    Phoenix.PubSub.broadcast(
      Polyphony.PubSub,
      progress_topic(scene_id),
      {:scene_progress,
       %{scene_id: scene_id, phase: phase, subject: opts[:subject], beat: opts[:beat]}}
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  The `{topic, message}` pairs to publish for one committed event: one per viewer
  who can see it. The omniscient viewer plus every character in `roster` is a
  candidate; `visible_to?/3` filters.
  """
  @spec fan_out(term(), struct(), term(), [term()], Visibility.member_at?()) ::
          [{String.t(), map()}]
  def fan_out(scene_id, %PacketSuperseded{} = event, _seq, roster, member_at?) do
    # A re-roll eviction (§7). Framing, not fiction — the payload is an opaque
    # `packet_id` to drop — so it goes to every viewer who could have rendered the
    # packet: its own character plus whoever was a member at the beat (the same
    # reach as an action/demeanor), plus the omniscient user who triggered it.
    message = %{
      type: "packet.superseded",
      scene_id: event.scene_id,
      beat: event.beat,
      character_id: event.character_id,
      packet_id: event.packet_id
    }

    ([:omniscient, {:character, event.character_id}] ++
       for(c <- roster, member_at?.(scene_id, c, event.beat), do: {:character, c}))
    |> Enum.uniq()
    |> Enum.map(fn viewer ->
      {topic(scene_id, viewer), Map.put(message, :viewer, viewer_tag(viewer))}
    end)
  end

  def fan_out(scene_id, event, seq, roster, member_at?) do
    case framing_message(event) do
      nil -> fan_out_event(scene_id, event, seq, roster, member_at?)
      framing -> [{topic(scene_id, :omniscient), framing}]
    end
  end

  defp fan_out_event(scene_id, event, seq, roster, member_at?) do
    message = message(event, seq)

    [:omniscient | Enum.map(roster, &{:character, &1})]
    |> Enum.uniq()
    |> Enum.filter(&Visibility.visible_to?(event, &1, member_at?))
    |> Enum.map(fn viewer ->
      {topic(scene_id, viewer), Map.put(message, :viewer, viewer_tag(viewer))}
    end)
  end

  # Beat framing is a user/system-only pacing signal — not part of the
  # authoritative `event.committed` cursor. It goes to the omniscient topic and
  # is re-derived (not replayed) on reconnect. (Generation failures are owned by
  # `Polyphony.Failures`, which broadcasts `generation.failed` with a retry
  # affordance and a `failure_id`.)
  defp framing_message(%BeatOpened{} = e),
    do: %{
      type: "beat.opened",
      viewer: "omniscient",
      scene_id: e.scene_id,
      beat: e.beat,
      cast: e.cast
    }

  defp framing_message(%BeatClosed{} = e),
    do: %{
      type: "beat.closed",
      viewer: "omniscient",
      scene_id: e.scene_id,
      beat: e.beat,
      completed: e.completed,
      failed: e.failed,
      passed: e.passed || []
    }

  defp framing_message(_), do: nil

  @doc """
  The messages a reconnecting viewer should replay: every event on the scene
  stream that is visible to them and past their `from_seq` cursor. `events` is a
  list of `{seq, event}` in log order.
  """
  @spec replay([{term(), struct()}], viewer(), Visibility.member_at?(), term()) :: [map()]
  def replay(events, viewer, member_at?, from_seq) do
    # Drop re-rolled packets and the markers themselves, so a reconnecting client
    # replays only the canonical log (§7) — never a stale, superseded turn.
    dead = events |> Enum.map(fn {_seq, event} -> event end) |> Packets.superseded_ids()

    events
    |> Enum.reject(fn {_seq, event} -> replay_drop?(event, dead) end)
    |> Enum.filter(fn {seq, event} ->
      seq_after?(seq, from_seq) and Visibility.visible_to?(event, viewer, member_at?)
    end)
    |> Enum.map(fn {seq, event} -> Map.put(message(event, seq), :viewer, viewer_tag(viewer)) end)
  end

  defp replay_drop?(%PacketSuperseded{}, _dead), do: true

  defp replay_drop?(event, dead) do
    case Map.get(event, :packet_id) do
      id when is_binary(id) -> MapSet.member?(dead, id)
      _ -> false
    end
  end

  @doc "The client message for a committed event (an `event.committed` payload)."
  @spec message(struct(), term()) :: map()
  def message(event, seq) do
    %{
      type: "event.committed",
      seq: seq,
      kind: kind(event),
      payload: payload(event)
    }
  end

  @doc "The scene id an event belongs to, or nil for non-scene events."
  def scene_id_of(%{scene_id: scene_id}), do: scene_id
  def scene_id_of(_), do: nil

  @doc "Character ids referenced by an event (for assembling the scene roster)."
  def character_ids(%ThoughtOccurred{character_id: id}), do: [id]
  def character_ids(%PrivateStateReported{character_id: id}), do: [id]
  def character_ids(%SpeechUttered{speaker_id: id, addressed_to: to}), do: [id | to || []]
  def character_ids(%ActionTaken{character_id: id}), do: [id]
  def character_ids(%DemeanorReported{character_id: id}), do: [id]
  def character_ids(%CharacterEntered{character_id: id}), do: [id]
  def character_ids(%CharacterExited{character_id: id}), do: [id]
  def character_ids(_), do: []

  # ── Message shaping ──────────────────────────────────────────────────────────

  defp viewer_tag(:omniscient), do: "omniscient"
  defp viewer_tag({:character, id}), do: "character:#{id}"

  defp kind(%mod{}), do: mod |> Module.split() |> List.last()

  defp payload(event) do
    event
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {k, jsonable(v)} end)
  end

  defp jsonable(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: to_string(v)
  defp jsonable(v), do: v

  defp seq_after?(_seq, nil), do: true
  defp seq_after?(seq, from) when is_integer(seq) and is_integer(from), do: seq > from
  defp seq_after?(_seq, _from), do: true
end
