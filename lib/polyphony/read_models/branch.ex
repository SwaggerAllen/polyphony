defmodule Polyphony.ReadModels.Branch do
  @moduledoc """
  The `branches` table (STR-8): one row per line in a campaign's tree.

  `ReadModels.SceneFork` records *scene* lineage — the raw material `Fork.fork/3`
  writes. A branch is the *campaign-level* line built on top of it: the thing the
  navigator lists, the hub scopes to, and canonical points at. Lineage here is a
  parent branch and a cut beat; the origin scene is a label, so navigation never
  depends on a scene surviving.

  Like the other read models, the SQL lives here so `Polyphony.Branching` is thin
  and the tests exercise the real queries.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "branches" do
    field(:campaign_id, :string)
    field(:parent_id, :integer)
    field(:origin_scene_id, :string)
    field(:cut_beat, :integer)
    field(:name, :string)
    field(:canonical, :boolean, default: false)
    field(:archived_at, :naive_datetime_usec)
    field(:cursor_scene_id, :string)
    field(:cursor_beat, :integer)
    field(:scene_ids, {:array, :string}, default: [])
    timestamps(type: :naive_datetime_usec)
  end

  def get(repo, id), do: repo.get(__MODULE__, id)

  @doc "Every line in a campaign, oldest first — the raw material for the tree."
  def list_for_campaign(repo, campaign_id) do
    cid = to_string(campaign_id)
    repo.all(from(b in __MODULE__, where: b.campaign_id == ^cid, order_by: b.id))
  end

  @doc "The campaign's canonical line, or nil when it has never branched."
  def canonical(repo, campaign_id) do
    cid = to_string(campaign_id)
    repo.one(from(b in __MODULE__, where: b.campaign_id == ^cid and b.canonical))
  end

  @doc "The line that claims `scene_id`, or nil — nil means the root line owns it."
  def of_scene(repo, campaign_id, scene_id) do
    cid = to_string(campaign_id)
    sid = to_string(scene_id)

    repo.one(
      from(b in __MODULE__,
        where: b.campaign_id == ^cid and ^sid in b.scene_ids,
        limit: 1
      )
    )
  end

  @doc "Direct children, oldest first."
  def children(repo, branch_id),
    do: repo.all(from(b in __MODULE__, where: b.parent_id == ^branch_id, order_by: b.id))
end
