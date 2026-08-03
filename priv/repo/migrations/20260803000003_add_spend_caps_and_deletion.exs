defmodule Polyphony.Repo.Migrations.AddSpendCapsAndDeletion do
  @moduledoc """
  A daily cap somebody can actually change, and a deletion that's on a clock
  (`ux/polyphony-settings-auth.html` §00, §04).

  The error copy already said *you can raise it in Settings* and there was nothing in
  Settings to raise: the cap lived in app config, identical for everyone, editable only
  by a deploy. `daily_cap` makes it the account's own number; a null means "use the
  configured default", so nothing has to be backfilled and the default stays a default
  rather than being frozen into every existing row.

  `deletion_requested_at` is the other half of *sign back in within 30 days and none of
  this happens*: leaving is a decision on a clock, not an event, and the clock has to be
  somewhere the account itself can carry it.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      # Micro-cents, matching the ledger's unit. Null = the configured default.
      add(:daily_cap, :bigint)
      add(:deletion_requested_at, :naive_datetime_usec)
    end

    create(index(:users, [:deletion_requested_at]))
  end
end
