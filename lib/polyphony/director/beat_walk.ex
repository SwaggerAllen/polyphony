defmodule Polyphony.Director.BeatWalk do
  @moduledoc """
  The shared beat-walk **decision** (§A1/§A2): given a scene and beat, what is the
  next slot that needs action, and how is it driven?

  Both beat loops consult this — the inline `Director.Runner` and the Oban-driven
  `Director.BeatDriver` — so there is exactly one place that knows the walk rules
  (declared order, terminal slots, control modes). The two differ only in how they
  *act* on the answer: the inline runner generates synchronously and returns; the
  Oban path enqueues a job or pauses. Neither re-implements the decision.

  Progress is re-derived from the log every call — committed packets (canonical
  scene stream) plus passed/failed (beat stream) — so the walk resumes after a
  pause without holding any state.
  """

  alias Polyphony.{Packets, TurnOrder}
  alias Polyphony.Events.{PacketPassed, PacketFailed}
  alias Polyphony.Director.BeatOps

  @type slot :: {:autonomous | :user_controlled | :assisted, term()} | :settled

  @doc "The next actionable slot for the beat, or `:settled` when every slot is terminal."
  @spec next(term(), integer()) :: slot()
  def next(scene_id, beat) do
    events = scene_id |> BeatOps.stored_events() |> Packets.canonical()
    order = TurnOrder.for_beat(events, beat) || []
    done = terminal_chars(scene_id, beat, events)

    case Enum.find(order, &(&1 not in done)) do
      nil -> :settled
      character_id -> {mode(events, character_id), character_id}
    end
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
