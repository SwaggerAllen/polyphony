defmodule Polyphony.IntegrationTest do
  @moduledoc """
  End-to-end vertical slice (§15 slices 1–2): real commands dispatched through
  Commanded → events committed to the store → the visibility projection filters
  the *actual* stored stream. No LLM. This proves the pieces compose, not just
  that each unit works.

  Membership is derived from the stored stream via `MembershipSet` (the pure twin
  of the Postgres read model, whose SQL is tested in
  `Polyphony.ReadModels.MembershipTest`), so the guarantee is exercised over real
  events without coupling to the projector process.
  """
  use ExUnit.Case, async: false

  alias Polyphony.App
  alias PolyphonyCore.{MembershipSet, Visibility}
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias PolyphonyCore.Events.{ThoughtOccurred, SpeechUttered}

  defp stored_events(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
  end

  test "dramatic irony holds over the real event store" do
    scene = "scene-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "alice", beat: 1})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "bram", beat: 1})

    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "I can't let him know"},
        %Move{seq: 2, type: :speech, content: "Lovely evening, isn't it?"}
      ],
      self_state: %SelfState{mood_felt: "panicked", demeanor: "serene"}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "alice",
        beat: 2,
        packet_id: scene <> "-2-alice",
        packet: packet
      })

    events = stored_events(scene)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()

    bram_view = Visibility.project(events, {:character, "bram"}, member_at?)
    alice_view = Visibility.project(events, {:character, "alice"}, member_at?)

    # Bram hears Alice's line but structurally cannot see the thought behind it.
    assert Enum.any?(bram_view, &match?(%SpeechUttered{content: "Lovely evening, isn't it?"}, &1))
    refute Enum.any?(bram_view, &match?(%ThoughtOccurred{}, &1))

    # Alice sees her own interior; the omniscient user sees everything.
    assert Enum.any?(alice_view, &match?(%ThoughtOccurred{content: "I can't let him know"}, &1))

    assert Enum.any?(
             Visibility.project(events, :omniscient, member_at?),
             &match?(%ThoughtOccurred{}, &1)
           )
  end
end
