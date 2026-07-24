defmodule Polyphony.Director.BeatIntegrationTest do
  @moduledoc """
  The beat lifecycle through real Commanded dispatch (router + aggregate),
  confirming the §12 join point commits. In-memory event store — no DB.
  """
  use ExUnit.Case, async: false

  alias Polyphony.App
  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, CloseBeat}
  alias Polyphony.Events.BeatClosed

  defp stored(beat_ref) do
    App |> Commanded.EventStore.stream_forward(to_string(beat_ref)) |> Enum.map(& &1.data)
  end

  test "open → record/fail cast → close emits BeatClosed with the split" do
    ref = "beat-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: ref,
        scene_id: "S1",
        beat: 3,
        cast: ["mira", "otto", "bram"]
      })

    :ok = App.dispatch(%RecordPacket{beat_ref: ref, character_id: "mira"})
    :ok = App.dispatch(%RecordFailure{beat_ref: ref, character_id: "otto", reason: "refusal"})
    :ok = App.dispatch(%RecordPacket{beat_ref: ref, character_id: "bram"})
    :ok = App.dispatch(%CloseBeat{beat_ref: ref})

    # Reasons round-trip through the JSON event store, so they come back as
    # strings — worth pinning, since downstream code reads them off the log.
    assert %BeatClosed{
             scene_id: "S1",
             beat: 3,
             completed: ["bram", "mira"],
             failed: [%{character_id: "otto", reason: "refusal"}]
           } = Enum.find(stored(ref), &match?(%BeatClosed{}, &1))
  end
end
