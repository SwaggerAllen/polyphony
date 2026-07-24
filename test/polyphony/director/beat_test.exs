defmodule Polyphony.Director.BeatTest do
  @moduledoc """
  The beat aggregate as pure functions — the §12 synchronization unit. One
  failure must not roll back the others; the close carries the failure list and
  scene framing.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Director.Beat
  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, CloseBeat}
  alias Polyphony.Events.{BeatOpened, BeatClosed, PacketRecorded, PacketFailed}

  defp evolve(state \\ %Beat{}, events), do: Enum.reduce(events, state, &Beat.apply(&2, &1))

  defp opened(cast \\ ["a", "b", "c"]) do
    evolve([%BeatOpened{beat_ref: "S1-b1", scene_id: "S1", beat: 1, cast: cast}])
  end

  defp open_beat(cast \\ ["a", "b"]) do
    %OpenBeat{beat_ref: "S1-b1", scene_id: "S1", beat: 1, cast: cast}
  end

  test "opening a beat emits BeatOpened with the cast and scene framing" do
    assert %BeatOpened{beat_ref: "S1-b1", scene_id: "S1", beat: 1, cast: ["a", "b"]} =
             Beat.execute(%Beat{}, open_beat())
  end

  test "opening twice is rejected" do
    assert {:error, :beat_already_opened} = Beat.execute(opened(), open_beat())
  end

  test "recording a cast member's packet emits PacketRecorded" do
    assert %PacketRecorded{beat_ref: "S1-b1", character_id: "a"} =
             Beat.execute(opened(), %RecordPacket{beat_ref: "S1-b1", character_id: "a"})
  end

  test "recording a non-cast character is rejected" do
    assert {:error, :not_in_cast} =
             Beat.execute(opened(), %RecordPacket{beat_ref: "S1-b1", character_id: "z"})
  end

  test "a duplicate record is an idempotent no-op" do
    state = opened() |> evolve([%PacketRecorded{beat_ref: "S1-b1", character_id: "a"}])
    assert [] = Beat.execute(state, %RecordPacket{beat_ref: "S1-b1", character_id: "a"})
  end

  test "recording a failure emits PacketFailed with scene framing and spares successes (§12)" do
    state = opened() |> evolve([%PacketRecorded{beat_ref: "S1-b1", character_id: "a"}])

    assert %PacketFailed{
             beat_ref: "S1-b1",
             scene_id: "S1",
             beat: 1,
             character_id: "b",
             reason: :refusal
           } =
             Beat.execute(state, %RecordFailure{
               beat_ref: "S1-b1",
               character_id: "b",
               reason: :refusal
             })
  end

  test "closing emits BeatClosed with scene framing, completed, and failed" do
    state =
      opened()
      |> evolve([
        %PacketRecorded{beat_ref: "S1-b1", character_id: "a"},
        %PacketFailed{beat_ref: "S1-b1", character_id: "b", reason: :timeout},
        %PacketRecorded{beat_ref: "S1-b1", character_id: "c"}
      ])

    assert %BeatClosed{
             beat_ref: "S1-b1",
             scene_id: "S1",
             beat: 1,
             completed: ["a", "c"],
             failed: [%{character_id: "b", reason: :timeout}]
           } = Beat.execute(state, %CloseBeat{beat_ref: "S1-b1"})
  end

  test "late arrivals after close are rejected (causality, §12)" do
    closed = opened() |> evolve([%BeatClosed{beat_ref: "S1-b1", completed: [], failed: []}])

    assert {:error, :beat_not_open} =
             Beat.execute(closed, %RecordPacket{beat_ref: "S1-b1", character_id: "a"})
  end

  test "settled? is true only once every cast member is terminal" do
    refute Beat.settled?(
             opened()
             |> evolve([%PacketRecorded{beat_ref: "S1-b1", character_id: "a"}])
           )

    all =
      opened()
      |> evolve([
        %PacketRecorded{beat_ref: "S1-b1", character_id: "a"},
        %PacketRecorded{beat_ref: "S1-b1", character_id: "b"},
        %PacketFailed{beat_ref: "S1-b1", character_id: "c", reason: :x}
      ])

    assert Beat.settled?(all)
  end
end
