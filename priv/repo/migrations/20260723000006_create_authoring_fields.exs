defmodule Polyphony.Repo.Migrations.CreateAuthoringFields do
  use Ecto.Migration

  # Field-level authoring metadata (§15), keyed by (subject, field). Kept in its
  # OWN table — deliberately separate from any generation schema — so lock flags,
  # feedback, and provenance never leak into the prompt (Instructor would derive
  # the JSON schema from the struct and the model would try to generate them).
  def change do
    create table(:authoring_fields) do
      add :subject_id, :string, null: false
      add :subject_type, :string, null: false, default: "character"
      add :field, :string, null: false
      add :value, :text
      add :status, :string, null: false, default: "draft"
      add :feedback, {:array, :string}, null: false, default: []
      add :model, :string
      add :prompt_hash, :string

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:authoring_fields, [:subject_id, :field])
  end
end
