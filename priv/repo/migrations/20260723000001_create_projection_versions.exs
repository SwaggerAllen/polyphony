defmodule Polyphony.Repo.Migrations.CreateProjectionVersions do
  use Ecto.Migration

  # Bookkeeping table used by Commanded.Projections.Ecto to record the last
  # event each projector has handled, so projections resume rather than replay.
  def change do
    create table(:projection_versions, primary_key: false) do
      add :projection_name, :text, primary_key: true
      add :last_seen_event_number, :bigint

      timestamps(type: :naive_datetime_usec)
    end
  end
end
