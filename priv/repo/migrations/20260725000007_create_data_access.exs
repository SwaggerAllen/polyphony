defmodule Polyphony.Repo.Migrations.CreateDataAccess do
  use Ecto.Migration

  def change do
    # §C: proactive-analysis opt-out at the ACCOUNT level, enforced at the data
    # layer. Presence of the timestamp means the account has opted out of proactive
    # analysis (reactive/report-triggered access ignores this).
    alter table(:users) do
      add(:proactive_opt_out_at, :naive_datetime_usec)
    end

    # Per-campaign proactive opt-out (§C): a row exists only for a campaign that has
    # opted out.
    create table(:campaign_data_prefs) do
      add(:campaign_id, :string, null: false)
      add(:proactive_opt_out, :boolean, null: false, default: false)
      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:campaign_data_prefs, [:campaign_id]))
  end
end
