defmodule Polyphony.SerializationTest do
  @moduledoc """
  Atom-valued event fields must survive the JSON event-store round-trip, or the
  core guarantee leaks: a whisper read back from the log would arrive with
  `audibility: "private"` (string), miss `Visibility`'s `:private` clause, and be
  treated as normal speech — visible to non-addressees.
  """
  use ExUnit.Case, async: false

  alias Polyphony.App
  alias PolyphonyCore.{MembershipSet, Visibility}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias PolyphonyCore.Events.SpeechUttered

  defp stored(s), do: App |> Commanded.EventStore.stream_forward(s) |> Enum.map(& &1.data)

  test "a private whisper read back from the store stays private" do
    s = "wh-#{System.unique_integer([:positive])}"
    :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})

    for c <- ["a", "b", "c"],
        do: App.dispatch(%EnterCharacter{scene_id: s, character_id: c, beat: 1})

    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :speech, content: "psst", addressed_to: ["b"], audibility: :private}
      ],
      self_state: %SelfState{}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: s,
        character_id: "a",
        beat: 2,
        packet_id: "#{s}-2-a",
        packet: packet
      })

    events = stored(s)
    speech = Enum.find(events, &match?(%SpeechUttered{}, &1))
    assert speech.audibility == :private, ~s(audibility must round-trip as an atom, not "private")

    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()

    # b is addressed → hears it; c is a member at the beat but not addressed → must not.
    assert Enum.any?(
             Visibility.project(events, {:character, "b"}, member_at?),
             &match?(%SpeechUttered{}, &1)
           )

    refute Enum.any?(
             Visibility.project(events, {:character, "c"}, member_at?),
             &match?(%SpeechUttered{}, &1)
           )
  end
end
