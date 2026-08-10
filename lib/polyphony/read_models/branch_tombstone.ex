defmodule Polyphony.ReadModels.BranchTombstone do
  @moduledoc """
  The record a deleted line leaves behind (STR-8): its id, its parent, the beat it
  was cut at, and the scenes it held. Small, permanent, and the thing that makes a
  circulating link answerable at all — `share.md` settles that a dead link is the
  common case and the person holding one did nothing wrong, so a deleted branch
  must never 404.

  Resolution walks parent pointers upward until it finds a surviving branch. The
  walk always terminates, because canonical can be neither deleted nor archived.
  `scene_ids` is what lets a link that names a *scene* of the deleted line find
  this tombstone at all — the branch row that knew the mapping is gone.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "branch_tombstones" do
    field(:branch_id, :integer)
    field(:campaign_id, :string)
    field(:parent_id, :integer)
    field(:cut_beat, :integer)
    field(:origin_scene_id, :string)
    field(:scene_ids, {:array, :string}, default: [])
    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  def put(repo, attrs) do
    repo.insert!(
      %__MODULE__{
        branch_id: Map.fetch!(attrs, :branch_id),
        campaign_id: to_string(Map.fetch!(attrs, :campaign_id)),
        parent_id: Map.get(attrs, :parent_id),
        cut_beat: Map.get(attrs, :cut_beat),
        origin_scene_id: Map.get(attrs, :origin_scene_id),
        scene_ids: Map.get(attrs, :scene_ids) || []
      },
      on_conflict: :nothing,
      conflict_target: [:branch_id]
    )
  end

  def get(repo, branch_id), do: repo.get_by(__MODULE__, branch_id: branch_id)

  @doc "The tombstone of the deleted line that held `scene_id`, or nil."
  def of_scene(repo, campaign_id, scene_id) do
    cid = to_string(campaign_id)
    sid = to_string(scene_id)

    repo.one(
      from(t in __MODULE__,
        where: t.campaign_id == ^cid and ^sid in t.scene_ids,
        limit: 1
      )
    )
  end
end
