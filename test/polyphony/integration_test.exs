defmodule Polyphony.IntegrationTest do
  @moduledoc """
  End-to-end vertical slice (§15 slices 1–2): real commands dispatched through
  Commanded → events committed to the store → the projector materializes the
  membership read model → the visibility projection filters the *actual* stored
  stream. No LLM. This proves the pieces compose, not just that each unit works.
  """
  # Not async: the projector runs in its own process, so we share the sandbox.
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo, Visibility}
  alias Polyphony.Projectors.SceneMemberships
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Events.{ThoughtOccurred, SpeechUttered}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end

  defp stored_events(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
  end

  test "dramatic irony holds over the real event store and read model" do
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

    # The projector catches up asynchronously; wait for membership to land.
    wait_until(fn -> SceneMemberships.member_at?(scene, "alice", 2) end)

    # Membership read model reflects both entrants at beat 2.
    assert Enum.sort(SceneMemberships.members_at(scene, 2)) == ["alice", "bram"]

    events = stored_events(scene)
    member_at? = SceneMemberships.member_at_fun()

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
