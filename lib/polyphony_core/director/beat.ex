defmodule PolyphonyCore.Director.Beat do
  @moduledoc """
  The beat aggregate — the §12 synchronization unit.

  A beat is opened with an ordered cast, then each cast member's job reports back
  as it reaches a terminal state (committed or failed). The beat is **not
  atomic**: one failure must not roll back the others, and a silent character is
  narratively survivable. When the beat closes it emits `BeatClosed{completed,
  failed}` — the one clean join point the Director subscribes to, carrying the
  failure list so it can route around a silent character next beat.

  Identity is `beat_ref` (the aggregate's stream id, e.g. `"scene-b2"`); the
  aggregate also holds `scene_id` and the integer `beat` so its events can carry
  scene framing to the client. Late arrivals after close are rejected (§12).
  """

  alias PolyphonyCore.Director.Commands.{
    OpenBeat,
    RecordPacket,
    RecordFailure,
    RecordPass,
    CloseBeat
  }

  alias PolyphonyCore.Events.{BeatOpened, BeatClosed, PacketRecorded, PacketFailed, PacketPassed}

  defstruct beat_ref: nil,
            scene_id: nil,
            beat: nil,
            status: :pending,
            cast: [],
            completed: MapSet.new(),
            failed: %{},
            passed: MapSet.new()

  # ── Commands ────────────────────────────────────────────────────────────────

  def execute(%__MODULE__{status: :pending}, %OpenBeat{} = c) do
    %BeatOpened{beat_ref: c.beat_ref, scene_id: c.scene_id, beat: c.beat, cast: c.cast}
  end

  def execute(%__MODULE__{}, %OpenBeat{}), do: {:error, :beat_already_opened}

  def execute(%__MODULE__{status: :open} = s, %RecordPacket{character_id: id}) do
    cond do
      id not in s.cast -> {:error, :not_in_cast}
      MapSet.member?(s.completed, id) -> []
      Map.has_key?(s.failed, id) -> {:error, :already_failed}
      true -> %PacketRecorded{beat_ref: s.beat_ref, character_id: id}
    end
  end

  def execute(%__MODULE__{}, %RecordPacket{}), do: {:error, :beat_not_open}

  def execute(%__MODULE__{status: :open} = s, %RecordFailure{character_id: id} = c) do
    cond do
      id not in s.cast ->
        {:error, :not_in_cast}

      MapSet.member?(s.completed, id) ->
        {:error, :already_completed}

      Map.has_key?(s.failed, id) ->
        []

      true ->
        %PacketFailed{
          beat_ref: s.beat_ref,
          scene_id: s.scene_id,
          beat: s.beat,
          character_id: id,
          reason: c.reason
        }
    end
  end

  def execute(%__MODULE__{}, %RecordFailure{}), do: {:error, :beat_not_open}

  def execute(%__MODULE__{status: :open} = s, %RecordPass{character_id: id}) do
    cond do
      id not in s.cast -> {:error, :not_in_cast}
      MapSet.member?(s.completed, id) -> {:error, :already_completed}
      Map.has_key?(s.failed, id) -> {:error, :already_failed}
      MapSet.member?(s.passed, id) -> []
      true -> %PacketPassed{beat_ref: s.beat_ref, character_id: id}
    end
  end

  def execute(%__MODULE__{}, %RecordPass{}), do: {:error, :beat_not_open}

  def execute(%__MODULE__{status: :open} = s, %CloseBeat{}) do
    %BeatClosed{
      beat_ref: s.beat_ref,
      scene_id: s.scene_id,
      beat: s.beat,
      completed: s.completed |> MapSet.to_list() |> Enum.sort(),
      failed: s.failed |> Enum.map(fn {id, reason} -> %{character_id: id, reason: reason} end),
      passed: s.passed |> MapSet.to_list() |> Enum.sort()
    }
  end

  def execute(%__MODULE__{}, %CloseBeat{}), do: {:error, :beat_not_open}

  # ── State ───────────────────────────────────────────────────────────────────

  def apply(%__MODULE__{} = s, %BeatOpened{} = e),
    do: %{
      s
      | status: :open,
        beat_ref: e.beat_ref,
        scene_id: e.scene_id,
        beat: e.beat,
        cast: e.cast
    }

  def apply(%__MODULE__{} = s, %PacketRecorded{character_id: id}),
    do: %{s | completed: MapSet.put(s.completed, id)}

  def apply(%__MODULE__{} = s, %PacketFailed{character_id: id, reason: reason}),
    do: %{s | failed: Map.put(s.failed, id, reason)}

  def apply(%__MODULE__{} = s, %PacketPassed{character_id: id}),
    do: %{s | passed: MapSet.put(s.passed, id)}

  def apply(%__MODULE__{} = s, %BeatClosed{}), do: %{s | status: :closed}

  def apply(%__MODULE__{} = s, _e), do: s

  @doc """
  Has every cast member reached a terminal state? (Used by the runner to close.)
  A user-controlled member counts once they commit (completed) or skip (passed) —
  otherwise a beat awaiting user input could never close (§A1).
  """
  def settled?(%__MODULE__{cast: cast, completed: completed, failed: failed, passed: passed}) do
    Enum.all?(cast, fn id ->
      MapSet.member?(completed, id) or Map.has_key?(failed, id) or MapSet.member?(passed, id)
    end)
  end
end
