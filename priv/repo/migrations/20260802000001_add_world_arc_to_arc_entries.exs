defmodule Polyphony.Repo.Migrations.AddWorldArcToArcEntries do
  use Ecto.Migration

  # World arc (§2.8) reuses the arc_entries table via subject_type: "world"
  # (subject_id = campaign_id). Two nullable columns carry the world-only fields —
  # character rows leave them null, world rows leave sheet_field null:
  #
  #   * scope       — "global" (everyone comes to know) | "local" (known at a place first)
  #   * location_id — for a local fact, where it happened (the scene's location_id, §2.3)
  def change do
    alter table(:arc_entries) do
      add :scope, :string
      add :location_id, :string
    end
  end
end
