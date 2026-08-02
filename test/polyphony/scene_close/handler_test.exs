defmodule Polyphony.SceneClose.HandlerTest do
  @moduledoc """
  The scene-close fan-out trigger (§5.1 / §10): `SceneClosed` fans out into the
  retryable per-unit Oban jobs. The live handler is off in tests (it touches
  Postgres via `Oban.insert!`), so this drives its `handle/2` directly — the same
  enqueue the production subscription performs on each close.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Polyphony.Repo

  alias Polyphony.{App, Repo}
  alias Polyphony.SceneClose.Handler
  alias Polyphony.Events.SceneClosed
  alias Polyphony.Jobs.{SummarizeScene, ExtractArc}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket, CloseScene}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp build_scene do
    scene = "sch-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    packet = %TurnPacket{
      moves: [%Move{seq: 1, type: :speech, content: "Hello"}],
      self_state: %SelfState{demeanor: "calm"}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "mira",
        beat: 2,
        packet_id: scene <> "-2-mira",
        packet: packet
      })

    scene
  end

  test "SceneClosed fans out into per-viewer summary jobs and per-participant arc jobs" do
    scene = build_scene()

    assert :ok = Handler.handle(%SceneClosed{scene_id: scene, closed_beat: 3}, %{})

    # N+1 summaries (omniscient + each participant) and one arc job per participant,
    # resolving the configured provider/embedder at run time (no opts threaded).
    assert_enqueued(
      worker: SummarizeScene,
      args: %{"scene_id" => scene, "viewer" => "omniscient"}
    )

    assert_enqueued(worker: SummarizeScene, args: %{"scene_id" => scene, "viewer" => "mira"})
    assert_enqueued(worker: ExtractArc, args: %{"scene_id" => scene, "character_id" => "mira"})
  end

  test "closing a scene through the aggregate emits the SceneClosed the handler consumes" do
    scene = build_scene()

    # Prove the trigger event the handler subscribes to is actually produced on close.
    :ok = App.dispatch(%CloseScene{scene_id: scene, closed_beat: 3})

    closed =
      App
      |> Commanded.EventStore.stream_forward(scene)
      |> Enum.map(& &1.data)
      |> Enum.filter(&match?(%SceneClosed{}, &1))

    assert [%SceneClosed{scene_id: ^scene, closed_beat: 3}] = closed
  end
end
