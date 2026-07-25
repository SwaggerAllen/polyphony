defmodule Polyphony.ReadModels.SceneForkTest do
  @moduledoc "The scene_forks lineage read model (§7) — the SQL the projector runs."
  use ExUnit.Case, async: true

  alias Polyphony.Repo
  alias Polyphony.ReadModels.SceneFork

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "put/get records a fork's parent and fork beat" do
    SceneFork.put(Repo, %{
      scene_id: "child",
      parent_scene_id: "parent",
      fork_beat: 3,
      label: "detour",
      campaign_id: "c1"
    })

    row = SceneFork.get(Repo, "child")
    assert row.parent_scene_id == "parent"
    assert row.fork_beat == 3
    assert row.label == "detour"
  end

  test "put is idempotent on scene_id (safe on projector replay)" do
    attrs = %{scene_id: "child", parent_scene_id: "p", fork_beat: 1}
    SceneFork.put(Repo, attrs)
    SceneFork.put(Repo, attrs)

    assert length(SceneFork.list_children(Repo, "p")) == 1
  end

  test "list_children returns a parent's branches by fork beat; list_for_campaign spans them" do
    SceneFork.put(Repo, %{scene_id: "c2", parent_scene_id: "p", fork_beat: 5, campaign_id: "camp"})

    SceneFork.put(Repo, %{scene_id: "c1", parent_scene_id: "p", fork_beat: 2, campaign_id: "camp"})

    SceneFork.put(Repo, %{
      scene_id: "c3",
      parent_scene_id: "other",
      fork_beat: 1,
      campaign_id: "camp"
    })

    assert Enum.map(SceneFork.list_children(Repo, "p"), & &1.scene_id) == ["c1", "c2"]
    assert length(SceneFork.list_for_campaign(Repo, "camp")) == 3
  end
end
