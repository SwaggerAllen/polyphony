defmodule Polyphony.SceneCloseTest do
  @moduledoc """
  The scene-close fan-out end-to-end (§10): real committed events → N+1
  filtered summaries + arc proposals, stored. Mock provider + MockEmbedder, real
  Postgres for the read models.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo, SceneClose}
  alias Polyphony.ReadModels.{SceneSummary, ArcEntry}
  alias Polyphony.SceneClose.MockEmbedder
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp build_scene do
    scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "otto", beat: 1})

    packet = %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "A secret I keep"},
        %Move{seq: 2, type: :speech, content: "Shall we begin?"}
      ],
      self_state: %SelfState{mood_felt: "tense", demeanor: "calm"}
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

  test "produces N+1 summaries and per-participant arc proposals" do
    scene = build_scene()

    assert {:ok, result} =
             SceneClose.run(scene,
               provider: Polyphony.LLM.Mock,
               embedder: MockEmbedder,
               repo: Repo
             )

    assert Enum.sort(result.participants) == ["mira", "otto"]
    # omniscient + mira + otto
    assert result.summaries == 3
    assert result.arc_entries >= 2

    # Each viewer's summary is stored under its own key, retrievable in scope.
    q = elem(MockEmbedder.embed("Shall we begin?"), 1)
    assert [%{character_id: "mira"}] = SceneSummary.search(Repo, "mira", q, 5)
    assert [%{character_id: "otto"}] = SceneSummary.search(Repo, "otto", q, 5)

    assert [%{character_id: "omniscient"}] =
             SceneSummary.search(Repo, SceneSummary.omniscient_key(), q, 5)
  end

  test "arc proposals land as :proposed, awaiting the review gate" do
    scene = build_scene()

    {:ok, _} =
      SceneClose.run(scene, provider: Polyphony.LLM.Mock, embedder: MockEmbedder, repo: Repo)

    proposed = ArcEntry.list_proposed(Repo, "mira")
    assert proposed != []
    assert Enum.all?(proposed, &(&1.status == "proposed"))
    assert Enum.all?(proposed, &(&1.source_scene_id == scene))
  end

  test "the pipeline degrades rather than fails when a summary generation errors" do
    scene = build_scene()

    # A provider that always errors: summaries fail, but run/2 still returns and
    # arc extraction (also failing) doesn't crash the pipeline (§12).
    Application.put_env(:polyphony, :llm,
      provider: Polyphony.LLM.Stub,
      stub_response: {:error, :boom}
    )

    on_exit(fn -> Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Stub) end)

    assert {:ok, result} = SceneClose.run(scene, embedder: MockEmbedder, repo: Repo)
    assert result.summaries == 0
  end
end
