defmodule Polyphony.Director.BeatWalk do
  @moduledoc """
  The beat-walk **decision** (§A1/§A2): given a scene and beat, what is the next
  slot that needs action, and how is it driven?

  Kept separate from the acting so the walk rules (declared order, terminal slots,
  control modes) live in one pure place that `Director.BeatDriver` consults and
  that is testable in isolation from the job machinery.

  Progress is re-derived from the log every call — committed packets (canonical
  scene stream) plus passed/failed (beat stream) — so the walk resumes after a
  pause without holding any state.

  A slot is only actionable for someone who is **a member at that beat**. Membership
  is the projection over the log (rule 4), so this needs no extra state — and it is
  the backstop that keeps a turn order naming someone who isn't in the scene from
  becoming an unbounded loop: their `CommitPacket` can only ever be rejected
  (`:not_a_member`), which leaves the slot non-terminal, so without this guard the
  walk would re-enqueue the same generation forever.
  """

  alias PolyphonyCore.{MembershipSet, Packets, TurnOrder}
  alias PolyphonyCore.Events.{PacketPassed, PacketFailed}
  alias Polyphony.Director.BeatOps

  @type slot :: {:autonomous | :user_controlled | :assisted, term()} | :settled

  @doc "The next actionable slot for the beat, or `:settled` when every slot is terminal."
  @spec next(term(), integer()) :: slot()
  def next(scene_id, beat) do
    events = scene_id |> BeatOps.stored_events() |> Packets.canonical()
    order = TurnOrder.for_beat(events, beat) || []
    done = terminal_chars(scene_id, beat, events)
    present = members_at(events, scene_id, beat)

    case Enum.find(order, &(MapSet.member?(present, &1) and &1 not in done)) do
      nil -> :settled
      character_id -> {mode(events, character_id), character_id}
    end
  end

  defp members_at(events, scene_id, beat) do
    events
    |> MembershipSet.from_events()
    |> MembershipSet.members_at(scene_id, beat)
    |> MapSet.new()
  end

  @doc "Characters whose slot is terminal: committed (canonical packet), passed, or failed."
  @spec terminal_chars(term(), integer(), [struct()]) :: MapSet.t()
  def terminal_chars(scene_id, beat, events) do
    committed = events |> Packets.beat_packets(beat) |> MapSet.new(fn {char, _} -> char end)
    beat_events = BeatOps.beat_events(scene_id, beat)
    passed = for %PacketPassed{character_id: c} <- beat_events, into: MapSet.new(), do: c
    failed = for %PacketFailed{character_id: c} <- beat_events, into: MapSet.new(), do: c

    committed |> MapSet.union(passed) |> MapSet.union(failed)
  end

  defp mode(events, character_id) do
    case TurnOrder.control_mode(events, character_id) do
      "user_controlled" -> :user_controlled
      "assisted" -> :assisted
      _ -> :autonomous
    end
  end
end
