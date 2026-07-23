defmodule Polyphony.Director.Beat do
  @moduledoc """
  The beat aggregate — the §12 synchronization unit.

  A beat is opened with an ordered cast, then each cast member's job reports back
  as it reaches a terminal state (committed or failed). The beat is **not
  atomic**: one failure must not roll back the others, and a silent character is
  narratively survivable. When the beat closes it emits `BeatClosed{completed,
  failed}` — the one clean join point the Director subscribes to, carrying the
  failure list so it can route around a silent character next beat.

  Late arrivals after close are rejected (§12): a packet landing in a later beat
  breaks the causality model.
  """

  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, CloseBeat}
  alias Polyphony.Events.{BeatOpened, BeatClosed, PacketRecorded, PacketFailed}

  defstruct beat: nil,
            status: :pending,
            cast: [],
            completed: MapSet.new(),
            failed: %{}

  # ── Commands ────────────────────────────────────────────────────────────────

  def execute(%__MODULE__{status: :pending}, %OpenBeat{} = c) do
    %BeatOpened{beat: c.beat, cast: c.cast}
  end

  def execute(%__MODULE__{}, %OpenBeat{}), do: {:error, :beat_already_opened}

  def execute(%__MODULE__{status: :open} = s, %RecordPacket{character_id: id} = c) do
    cond do
      id not in s.cast -> {:error, :not_in_cast}
      MapSet.member?(s.completed, id) -> []
      Map.has_key?(s.failed, id) -> {:error, :already_failed}
      true -> %PacketRecorded{beat: c.beat, character_id: id}
    end
  end

  def execute(%__MODULE__{}, %RecordPacket{}), do: {:error, :beat_not_open}

  def execute(%__MODULE__{status: :open} = s, %RecordFailure{character_id: id} = c) do
    cond do
      id not in s.cast -> {:error, :not_in_cast}
      MapSet.member?(s.completed, id) -> {:error, :already_completed}
      Map.has_key?(s.failed, id) -> []
      true -> %PacketFailed{beat: c.beat, character_id: id, reason: c.reason}
    end
  end

  def execute(%__MODULE__{}, %RecordFailure{}), do: {:error, :beat_not_open}

  def execute(%__MODULE__{status: :open} = s, %CloseBeat{} = c) do
    %BeatClosed{
      beat: c.beat,
      completed: s.completed |> MapSet.to_list() |> Enum.sort(),
      failed: s.failed |> Enum.map(fn {id, reason} -> %{character_id: id, reason: reason} end)
    }
  end

  def execute(%__MODULE__{}, %CloseBeat{}), do: {:error, :beat_not_open}

  # ── State ───────────────────────────────────────────────────────────────────

  def apply(%__MODULE__{} = s, %BeatOpened{} = e),
    do: %{s | status: :open, beat: e.beat, cast: e.cast}

  def apply(%__MODULE__{} = s, %PacketRecorded{character_id: id}),
    do: %{s | completed: MapSet.put(s.completed, id)}

  def apply(%__MODULE__{} = s, %PacketFailed{character_id: id, reason: reason}),
    do: %{s | failed: Map.put(s.failed, id, reason)}

  def apply(%__MODULE__{} = s, %BeatClosed{}), do: %{s | status: :closed}

  def apply(%__MODULE__{} = s, _e), do: s

  @doc "Has every cast member reached a terminal state? (Used by the runner to close.)"
  def settled?(%__MODULE__{cast: cast, completed: completed, failed: failed}) do
    Enum.all?(cast, fn id -> MapSet.member?(completed, id) or Map.has_key?(failed, id) end)
  end
end
