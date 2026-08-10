defmodule Polyphony.Repo.Migrations.CreateBranches do
  @moduledoc """
  A campaign's lines, as a tree (STR-8).

  `scene_forks` records scene-level lineage — one row per forked stream. A **branch**
  is the campaign-level line an author works in: it groups the scenes played on that
  line, knows which line it was cut from and at which beat, and carries the three
  facts the surfaces need — a name, whether it is canonical, and the divergence
  cursor.

  The tree is keyed on branches, not on scenes: lineage is a `parent_id` and a
  `cut_beat`, and the scene the cut happened in (`origin_scene_id`) is a label. That
  is what stops a deleted scene stranding its children.

  * **Canonical** is a pointer, one per campaign (partial unique index): what the hub
    opens on, what publishing points at, what a party follows. An authority claim
    about a session, not a verdict on the fiction.
  * **The cursor** is where the line diverges *now* — mutable, and it only moves
    earlier. The cut is where it *started* diverging and never moves.
  * **Deleting** a branch re-parents its children and leaves a tombstone (the line's
    id, its parent, the cut beat), so links into the deleted line stay answerable —
    the reader lands on the nearest surviving ancestor at the cut instead of a 404.
  """
  use Ecto.Migration

  def change do
    create table(:branches) do
      add(:campaign_id, :string, null: false)
      add(:parent_id, :bigint)
      add(:origin_scene_id, :string)
      add(:cut_beat, :integer)
      add(:name, :string, null: false)
      add(:canonical, :boolean, null: false, default: false)
      add(:archived_at, :naive_datetime_usec)
      add(:cursor_scene_id, :string)
      add(:cursor_beat, :integer)
      # The scenes played on this line, in play order. The root line claims nothing:
      # a scene no branch claims belongs to it, which keeps a never-branched campaign
      # free of bookkeeping.
      add(:scene_ids, {:array, :string}, null: false, default: [])
      timestamps(type: :naive_datetime_usec)
    end

    create(index(:branches, [:campaign_id]))
    create(index(:branches, [:parent_id]))

    create(
      unique_index(:branches, [:campaign_id],
        where: "canonical",
        name: :branches_one_canonical_per_campaign
      )
    )

    create table(:branch_tombstones) do
      add(:branch_id, :bigint, null: false)
      add(:campaign_id, :string, null: false)
      add(:parent_id, :bigint)
      add(:cut_beat, :integer)
      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create(unique_index(:branch_tombstones, [:branch_id]))
    create(index(:branch_tombstones, [:campaign_id]))
  end
end
