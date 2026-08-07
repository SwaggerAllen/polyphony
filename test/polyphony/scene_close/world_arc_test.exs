defmodule Polyphony.SceneClose.WorldArcTest do
  @moduledoc """
  World-arc extraction (§2.8): a scene close proposes durable world facts, keyed to
  the campaign, with a global/local scope. Local facts are stamped with the scene's
  location; a scene with no campaign has nowhere to attach world arc.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo, SceneClose, Library, Costs}
  alias Polyphony.ReadModels.ArcEntry
  alias Polyphony.LLM.{Mock, Stub}
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp build_scene(opts) do
    scene = "wa-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        campaign_id: opts[:campaign_id],
        location_id: opts[:location_id],
        opened_beat: 0
      })

    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "mira",
        beat: 2,
        packet_id: scene <> "-2-mira",
        packet: %TurnPacket{
          moves: [%Move{seq: 1, type: :speech, content: "The sky splits open."}],
          self_state: %SelfState{demeanor: "awed"}
        }
      })

    scene
  end

  test "stores a proposed global world fact keyed to the campaign" do
    scene = build_scene(campaign_id: "camp-1", location_id: "the docks")

    assert {:ok, 1} = SceneClose.extract_world(scene, provider: Mock, repo: Repo)

    assert [entry] = ArcEntry.list_proposed_world(Repo, "camp-1")
    assert entry.subject_type == "world"
    assert entry.kind == "discovery"
    assert entry.scope == "global"
    # A global fact is not tied to any place.
    assert entry.location_id == nil
    assert entry.source_scene_id == scene
  end

  test "a global fact carries no location; a local fact is stamped with the scene's location" do
    scene = build_scene(campaign_id: "camp-2", location_id: "the harbour")

    # Force a local-scope proposal to prove the scene's location is stamped on it.
    local = Jason.encode!(%{entries: [%{kind: "discovery", scope: "local", statement: "X."}]})

    assert {:ok, 1} =
             SceneClose.extract_world(scene,
               provider: Stub,
               respond_with: {:ok, local},
               repo: Repo
             )

    assert [entry] = ArcEntry.list_proposed_world(Repo, "camp-2")
    assert entry.subject_type == "world"
    assert entry.scope == "local"
    assert entry.location_id == "the harbour"
    assert entry.status == "proposed"
  end

  test "a scene with no campaign has nowhere to attach world arc" do
    scene = build_scene(campaign_id: nil, location_id: "nowhere")

    assert {:ok, 0} = SceneClose.extract_world(scene, provider: Mock, repo: Repo)
  end

  test "extraction is metered to the campaign owner (§B5)" do
    campaign = Library.put(%{owner_id: "7", kind: "campaign", payload: %{}})
    scene = build_scene(campaign_id: campaign.id, location_id: "the docks")

    assert {:ok, _} = SceneClose.extract_world(scene, provider: Mock, repo: Repo)
    assert {:ok, _} = SceneClose.extract_participant(scene, "mira", provider: Mock, repo: Repo)

    # The owner (user 7) is billed for both extractions, on their daily and the campaign.
    assert Costs.spent_campaign(campaign.id) > 0
    assert Costs.spent_today(7) > 0
  end
end
