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

  alias Polyphony.Visibility

  alias Polyphony.Events.{
    ThoughtOccurred,
    PrivateStateReported,
    SpeechUttered,
    ActionTaken,
    DemeanorReported,
    CharacterEntered,
    CharacterExited
  }

  @type viewer :: :omniscient | {:character, term()}

  @doc "The PubSub topic for a `(scene, viewer)` pair."
  @spec topic(term(), viewer()) :: String.t()
  def topic(scene_id, :omniscient), do: "scene:#{scene_id}:omniscient"
  def topic(scene_id, {:character, id}), do: "scene:#{scene_id}:character:#{id}"

  @doc """
  The `{topic, message}` pairs to publish for one committed event: one per viewer
  who can see it. The omniscient viewer plus every character in `roster` is a
  candidate; `visible_to?/3` filters.
  """
  @spec fan_out(term(), struct(), term(), [term()], Visibility.member_at?()) ::
          [{String.t(), map()}]
  def fan_out(scene_id, event, seq, roster, member_at?) do
    message = message(event, seq)

    [:omniscient | Enum.map(roster, &{:character, &1})]
    |> Enum.uniq()
    |> Enum.filter(&Visibility.visible_to?(event, &1, member_at?))
    |> Enum.map(fn viewer ->
      {topic(scene_id, viewer), Map.put(message, :viewer, viewer_tag(viewer))}
    end)
  end

  @doc """
  The messages a reconnecting viewer should replay: every event on the scene
  stream that is visible to them and past their `from_seq` cursor. `events` is a
  list of `{seq, event}` in log order.
  """
  @spec replay([{term(), struct()}], viewer(), Visibility.member_at?(), term()) :: [map()]
  def replay(events, viewer, member_at?, from_seq) do
    events
    |> Enum.filter(fn {seq, event} ->
      seq_after?(seq, from_seq) and Visibility.visible_to?(event, viewer, member_at?)
    end)
    |> Enum.map(fn {seq, event} -> Map.put(message(event, seq), :viewer, viewer_tag(viewer)) end)
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
