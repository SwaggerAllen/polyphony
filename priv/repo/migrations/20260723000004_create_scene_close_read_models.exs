defmodule Polyphony.Repo.Migrations.CreateSceneCloseReadModels do
  use Ecto.Migration

  # Scene-close read models (§8, §6.2). pgvector must be enabled for the
  # embedding column.
  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    # Per-character summaries (§8 fix #2). Keyed by character_id — "omniscient"
    # for the user's table-of-contents summary, a character id for each
    # participant's filtered summary — so the vector search scopes by whose view
    # it is *structurally*, not via a WHERE clause someone can forget.
    create table(:character_scene_summaries) do
      add :scene_id, :string, null: false
      add :character_id, :string, null: false
      add :summary, :text
      add :embedding, :vector, size: 8

      timestamps(type: :naive_datetime_usec)
    end

    create index(:character_scene_summaries, [:character_id])
    create unique_index(:character_scene_summaries, [:scene_id, :character_id])

    # Proposed arc entries (§6.2). Interpreted, campaign-scoped facts extracted at
    # scene close; everything enters :proposed and needs the review gate before it
    # becomes :canon (and only then feeds the effective sheet).
    create table(:arc_entries) do
      add :subject_id, :string, null: false
      add :subject_type, :string, default: "character"
      add :kind, :string, null: false
      add :sheet_field, :string
      add :statement, :text, null: false
      add :status, :string, null: false, default: "proposed"
      add :promotable, :boolean, default: true
      add :beat, :integer
      add :source_scene_id, :string

      timestamps(type: :naive_datetime_usec)
    end

    create index(:arc_entries, [:subject_id, :status])
  end
end
