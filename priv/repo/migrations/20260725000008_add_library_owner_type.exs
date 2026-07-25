defmodule Polyphony.Repo.Migrations.AddLibraryOwnerType do
  use Ecto.Migration

  def change do
    # Owner indirection (roadmap §P2/§P8): content ownership carries a `type` so it
    # can later be a user OR an org without re-encoding every id. Defaults to "user"
    # — every existing and v1 owner is a user.
    alter table(:library_entries) do
      add(:owner_type, :string, null: false, default: "user")
    end

    create(index(:library_entries, [:owner_type, :owner_id]))
  end
end
