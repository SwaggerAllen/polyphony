defmodule Polyphony.Repo.Migrations.CreateLibraryEntries do
  use Ecto.Migration

  def change do
    create table(:library_entries) do
      # Ownership (§B1): every owned authored entity — character sheet, world bible,
      # campaign, prompt-template override. Arc is NOT owned here; it is
      # campaign-scoped and travels with the campaign snapshot.
      add(:owner_id, :string, null: false)
      add(:kind, :string, null: false)

      # Visibility axis: private (default) / unlisted (share-token URL) / public.
      add(:visibility, :string, null: false, default: "private")
      add(:share_token, :string)

      # Version-pinning + attribution: a monotonic version per entry, and a pointer
      # back to the (entry, version) a fork/instantiate was derived from.
      add(:version, :integer, null: false, default: 1)
      add(:derived_from_id, :integer)
      add(:derived_from_version, :integer)

      # The live/frozen axis (independent of visibility): a published snapshot embeds
      # its dependencies and is frozen; a working entry references the live library.
      add(:frozen, :boolean, null: false, default: false)

      # The domain payload (sheet / bible / campaign Snapshot), stored as an Erlang
      # term — lossless, so nested authored structs round-trip exactly.
      add(:payload, :binary, null: false)

      timestamps(type: :naive_datetime_usec)
    end

    create(index(:library_entries, [:owner_id]))
    create(index(:library_entries, [:kind, :visibility]))
    create(unique_index(:library_entries, [:share_token], where: "share_token IS NOT NULL"))
  end
end
