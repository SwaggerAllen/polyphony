defmodule Polyphony.Director.BeatIntegrationTest do
  @moduledoc """
  The beat lifecycle through real Commanded dispatch (router + aggregate),
  confirming the §12 join point commits. In-memory event store — no DB.
  """
  use ExUnit.Case, async: false

  alias Polyphony.App
  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, CloseBeat}
  alias Polyphony.Events.BeatClosed

  defp stored(beat_id) do
    App |> Commanded.EventStore.stream_forward(to_string(beat_id)) |> Enum.map(& &1.data)
  end

  test "open → record/fail cast → close emits BeatClosed with the split" do
    beat = "beat-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok = App.dispatch(%OpenBeat{beat: beat, cast: ["mira", "otto", "bram"]})
    :ok = App.dispatch(%RecordPacket{beat: beat, character_id: "mira"})
    :ok = App.dispatch(%RecordFailure{beat: beat, character_id: "otto", reason: "refusal"})
    :ok = App.dispatch(%RecordPacket{beat: beat, character_id: "bram"})
    :ok = App.dispatch(%CloseBeat{beat: beat})

    # Reasons round-trip through the JSON event store, so they come back as
    # strings — worth pinning, since downstream code reads them off the log.
    assert %BeatClosed{
             completed: ["bram", "mira"],
             failed: [%{character_id: "otto", reason: "refusal"}]
           } = Enum.find(stored(beat), &match?(%BeatClosed{}, &1))
  end
end
