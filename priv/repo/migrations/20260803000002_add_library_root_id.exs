defmodule Polyphony.Repo.Migrations.AddLibraryRootId do
  @moduledoc """
  Root identity on derived entries (`completed-roadmap.md` §3.1d).

  Every campaign copies its world (§2.5b) and every fork copies everything, so within a
  year there are a dozen artifacts called Saltmarch. `derived_from_id` is a *parent*
  pointer, and walking the chain per row to group a list is the wrong shape — an N-deep
  fork tree turns a list render into N queries.

  `root_id` is the original every copy descends from, stamped once at copy time and
  carried forward, so grouping is a single indexed read. An original's root is itself,
  written explicitly rather than left null so a query never has to case on it.
  """
  use Ecto.Migration

  def up do
    alter table(:library_entries) do
      add(:root_id, :integer)
    end

    create(index(:library_entries, [:root_id]))

    # Backfill: an entry with no parent is its own root; a copy inherits its parent's
    # root, which for existing data is one level deep (nothing forks a fork yet).
    execute("UPDATE library_entries SET root_id = id WHERE derived_from_id IS NULL")

    execute("""
    UPDATE library_entries child
    SET root_id = COALESCE(parent.root_id, parent.id)
    FROM library_entries parent
    WHERE child.derived_from_id = parent.id AND child.root_id IS NULL
    """)

    execute("UPDATE library_entries SET root_id = id WHERE root_id IS NULL")
  end

  def down do
    drop(index(:library_entries, [:root_id]))

    alter table(:library_entries) do
      remove(:root_id)
    end
  end
end
