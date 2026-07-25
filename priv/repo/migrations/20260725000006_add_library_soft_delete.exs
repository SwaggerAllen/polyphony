defmodule Polyphony.Repo.Migrations.AddLibrarySoftDelete do
  use Ecto.Migration

  def change do
    # Soft-delete (§B9): campaigns are high-investment immutable logs, so prefer a
    # recoverable archive / delete over hard destruction. `archived_at` hides from
    # default lists (recoverable); `deleted_at` is the confirmed delete with a
    # recovery window before a purge. Forks are independent copies and never cascade.
    alter table(:library_entries) do
      add(:archived_at, :naive_datetime_usec)
      add(:deleted_at, :naive_datetime_usec)
    end

    create(index(:library_entries, [:deleted_at]))
  end
end
