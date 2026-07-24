defmodule Polyphony.SceneClose.RetriesTest do
  @moduledoc """
  Scene-close units classify failures for retry (§10, §12), and `enqueue/2` fans
  out into per-unit Oban jobs so transient failures back off.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Polyphony.Repo

  alias Polyphony.{App, Repo, SceneClose}
  alias Polyphony.ReadModels.{SceneSummary, ArcEntry}
  alias Polyphony.LLM.{Mock, Stub}
  alias Polyphony.SceneClose.MockEmbedder
  alias Polyphony.Jobs.{SummarizeScene, ExtractArc}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp build_scene do
    scene = "rt-" <> Integer.to_string(System.unique_integer([:positive]))
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

  describe "failure classification (§12)" do
    test "a summary transport error is transient — worth retrying" do
      scene = build_scene()

      assert {:error, :timeout} =
               SceneClose.summarize_viewer(scene, {:character, "mira"},
                 provider: Stub,
                 respond_with: {:error, :timeout},
                 embedder: MockEmbedder
               )
    end

    test "a summary succeeds and stores" do
      scene = build_scene()

      assert :ok =
               SceneClose.summarize_viewer(scene, {:character, "mira"},
                 provider: Mock,
                 embedder: MockEmbedder,
                 repo: Repo
               )
    end

    test "a schema-invalid arc extraction is permanent — cancel, don't loop" do
      scene = build_scene()

      assert {:cancel, :invalid_arc} =
               SceneClose.extract_participant(scene, "mira",
                 provider: Stub,
                 respond_with: {:ok, "not json"},
                 repo: Repo
               )
    end

    test "an arc transport error is transient — retry" do
      scene = build_scene()

      assert {:error, :down} =
               SceneClose.extract_participant(scene, "mira",
                 provider: Stub,
                 respond_with: {:error, :down},
                 repo: Repo
               )
    end
  end

  describe "enqueue/2 fans out per-unit jobs" do
    test "enqueues one summary job per viewer (N+1) and one arc job per participant" do
      scene = build_scene()

      assert {:ok, %{participants: ["mira"], summary_jobs: 2, arc_jobs: 1}} =
               SceneClose.enqueue(scene, provider: Mock, embedder: MockEmbedder)

      assert_enqueued(worker: SummarizeScene, args: %{"viewer" => "omniscient"})
      assert_enqueued(worker: SummarizeScene, args: %{"viewer" => "mira"})
      assert_enqueued(worker: ExtractArc, args: %{"character_id" => "mira"})
    end

    test "inline mode runs the jobs to completion, storing summaries and arc proposals" do
      scene = build_scene()

      Oban.Testing.with_testing_mode(:inline, fn ->
        SceneClose.enqueue(scene, provider: Mock, embedder: MockEmbedder)
      end)

      q = elem(MockEmbedder.embed("Hello"), 1)
      assert [%{character_id: "mira"}] = SceneSummary.search(Repo, "mira", q, 5)

      assert [%{character_id: "omniscient"}] =
               SceneSummary.search(Repo, SceneSummary.omniscient_key(), q, 5)

      assert ArcEntry.list_proposed(Repo, "mira") != []
    end
  end
end
