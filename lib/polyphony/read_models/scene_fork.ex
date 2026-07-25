defmodule Polyphony.ReadModels.SceneFork do
  @moduledoc """
  The `scene_forks` lineage read model (§7): one row per forked scene, recording
  its parent and the beat it branched at. Feeds the branch navigator (FS V2) — the
  scene graph is reconstructed from these parent pointers.

  Like the membership read model, the write/query SQL lives here so the projector
  is a thin wrapper and the tests exercise the real SQL directly.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "scene_forks" do
    field(:scene_id, :string)
    field(:parent_scene_id, :string)
    field(:fork_beat, :integer)
    field(:label, :string)
    field(:campaign_id, :string)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "Record a fork. Idempotent on `scene_id` (safe on projector replay)."
  def put(repo, attrs) do
    repo.insert!(
      %__MODULE__{
        scene_id: to_string(Map.get(attrs, :scene_id)),
        parent_scene_id: to_string(Map.get(attrs, :parent_scene_id)),
        fork_beat: Map.get(attrs, :fork_beat),
        label: Map.get(attrs, :label),
        campaign_id: Map.get(attrs, :campaign_id) && to_string(Map.get(attrs, :campaign_id))
      },
      on_conflict: :nothing,
      conflict_target: [:scene_id]
    )
  end

  @doc "The fork record for a scene, or nil if it isn't a fork."
  def get(repo, scene_id), do: repo.get_by(__MODULE__, scene_id: to_string(scene_id))

  @doc "Direct children of a scene — the branches taken from it, by fork beat."
  def list_children(repo, parent_scene_id) do
    pid = to_string(parent_scene_id)
    repo.all(from(f in __MODULE__, where: f.parent_scene_id == ^pid, order_by: f.fork_beat))
  end

  @doc "Every fork in a campaign — the raw material for the branch tree."
  def list_for_campaign(repo, campaign_id) do
    cid = to_string(campaign_id)
    repo.all(from(f in __MODULE__, where: f.campaign_id == ^cid))
  end
end
