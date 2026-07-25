defmodule Polyphony.Repo.Migrations.CreateCostLedger do
  use Ecto.Migration

  def change do
    # Per-user + per-campaign spend accounting (§B5). Append-only; sums drive the
    # cost dashboard and the circuit breaker. `amount` is in abstract cost units
    # (micro-cents), billing-ready for deferred payment features.
    create table(:cost_ledger) do
      # A plain id, not a FK: this is a high-volume, append-only accounting table
      # whose rows outlive the user (billing history survives account deletion).
      add(:user_id, :integer)
      add(:campaign_id, :string)
      add(:amount, :integer, null: false, default: 0)
      add(:kind, :string, null: false, default: "generation")
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create(index(:cost_ledger, [:user_id, :inserted_at]))
    create(index(:cost_ledger, [:campaign_id]))
  end
end
