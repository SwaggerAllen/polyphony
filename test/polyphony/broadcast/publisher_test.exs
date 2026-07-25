defmodule Polyphony.Broadcast.PublisherTest do
  @moduledoc """
  The live tail end-to-end (§13): dispatch real commands, and confirm each viewer
  receives only their filtered `event.committed` messages over PubSub. No DB — the
  publisher derives membership from the stream.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Broadcast}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Director.Commands.{OpenBeat, CloseBeat}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  defp collect(acc \\ []) do
    receive do
      {:polyphony_event, msg} -> collect([msg | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp kinds_for(msgs, viewer_tag) do
    msgs |> Enum.filter(&(&1.viewer == viewer_tag)) |> Enum.map(& &1.kind)
  end

  test "each viewer receives only what they can see" do
    scene = "pub-" <> Integer.to_string(System.unique_integer([:positive]))

    Phoenix.PubSub.subscribe(Polyphony.PubSub, Broadcast.topic(scene, :omniscient))
    Phoenix.PubSub.subscribe(Polyphony.PubSub, Broadcast.topic(scene, {:character, "otto"}))

    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "otto", beat: 1})

    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "I mustn't let on"},
        %Move{seq: 2, type: :speech, content: "Lovely to see you"}
      ],
      self_state: %SelfState{mood_felt: "anxious", demeanor: "warm"}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "mira",
        beat: 2,
        packet_id: scene <> "-2-mira",
        packet: packet
      })

    msgs = collect()

    omniscient = kinds_for(msgs, "omniscient")
    otto = kinds_for(msgs, "character:otto")

    # The user (omniscient) sees Mira's interior and her speech.
    assert "ThoughtOccurred" in omniscient
    assert "SpeechUttered" in omniscient

    # Otto hears the speech but never sees the thought or Mira's private state.
    assert "SpeechUttered" in otto
    refute "ThoughtOccurred" in otto
    refute "PrivateStateReported" in otto
  end

  test "beat framing reaches the omniscient viewer as beat.opened / beat.closed" do
    scene = "pub-" <> Integer.to_string(System.unique_integer([:positive]))
    ref = "#{scene}-b2"

    Phoenix.PubSub.subscribe(Polyphony.PubSub, Broadcast.topic(scene, :omniscient))

    :ok = App.dispatch(%OpenBeat{beat_ref: ref, scene_id: scene, beat: 2, cast: ["mira"]})
    :ok = App.dispatch(%CloseBeat{beat_ref: ref})

    types = collect() |> Enum.map(& &1.type)
    assert "beat.opened" in types
    assert "beat.closed" in types
  end
end
