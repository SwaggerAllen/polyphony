defmodule Polyphony.ReadModels.BranchTombstone do
  @moduledoc """
  The record a deleted line leaves behind (STR-8): its id, its parent, and the beat
  it was cut at. Small, permanent, and the thing that makes a circulating link
  answerable at all — `share.md` settles that a dead link is the common case and the
  person holding one did nothing wrong, so a deleted branch must never 404.

  Resolution walks parent pointers upward until it finds a surviving branch. The
  walk always terminates, because canonical can be neither deleted nor archived.
  """
  use Ecto.Schema

  schema "branch_tombstones" do
    field(:branch_id, :integer)
    field(:campaign_id, :string)
    field(:parent_id, :integer)
    field(:cut_beat, :integer)
    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  def put(repo, attrs) do
    repo.insert!(
      %__MODULE__{
        branch_id: Map.fetch!(attrs, :branch_id),
        campaign_id: to_string(Map.fetch!(attrs, :campaign_id)),
        parent_id: Map.get(attrs, :parent_id),
        cut_beat: Map.get(attrs, :cut_beat)
      },
      on_conflict: :nothing,
      conflict_target: [:branch_id]
    )
  end

  def get(repo, branch_id), do: repo.get_by(__MODULE__, branch_id: branch_id)
end
