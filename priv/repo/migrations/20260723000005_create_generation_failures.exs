defmodule Polyphony.Repo.Migrations.CreateGenerationFailures do
  use Ecto.Migration

  # User-facing failure log (§12). Every terminal failure — a refusal that
  # survived the model swap, a job that exhausted its retries — lands here with
  # enough to re-enqueue the exact work (`worker` + `args`) and a `retry`/`edit`
  # affordance for the user. `editable` marks refusals, which a user can rephrase
  # and resubmit.
  def change do
    create table(:generation_failures) do
      add :scene_id, :string
      add :beat, :integer
      add :subject, :string
      add :operation, :string
      add :kind, :string
      add :reason, :text
      add :editable, :boolean, null: false, default: false
      add :retryable, :boolean, null: false, default: true
      add :status, :string, null: false, default: "open"
      add :worker, :string, null: false
      add :args, :map, null: false, default: %{}

      timestamps(type: :naive_datetime_usec)
    end

    create index(:generation_failures, [:scene_id, :status])
  end
end
