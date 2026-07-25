defmodule Polyphony.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    create table(:users) do
      # Identity (§B2). Email is auth-only and must never surface on profile/owner
      # surfaces — username is the public handle.
      add(:email, :string, null: false)
      add(:username, :string, null: false)
      add(:display_name, :string)
      add(:avatar_url, :string)
      add(:bio, :text)

      # Role (planned addition #4): user / admin / superadmin. First sign-up →
      # superadmin, minted once and un-demotable.
      add(:role, :string, null: false, default: "user")

      # 18+ attestation — logged with a timestamp; its presence gates account
      # creation and is the non-configurable content floor (§A5).
      add(:attested_adult_at, :naive_datetime_usec)

      # Rate-limit anchor for username changes (§B2).
      add(:username_changed_at, :naive_datetime_usec)

      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:users, [:email]))
    create(unique_index(:users, [:username]))

    # There is exactly one superadmin (the first sign-up), enforced at the data
    # layer so even a race on "is this the first user?" can't mint a second.
    create(unique_index(:users, [:role], where: "role = 'superadmin'", name: :one_superadmin))

    # Single-use invite links (planned addition #5): admin-generated; the first user
    # bypasses. One redemption, ever.
    create table(:invites) do
      add(:token, :string, null: false)
      add(:created_by_id, references(:users, on_delete: :nilify_all))
      add(:redeemed_by_id, references(:users, on_delete: :nilify_all))
      add(:redeemed_at, :naive_datetime_usec)
      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:invites, [:token]))
    create(index(:invites, [:created_by_id]))

    # Versioned consent log (§B2): append-only. Content-policy explainer + TOS +
    # privacy acceptance, each recorded with version + timestamp; a material version
    # bump re-prompts on next sign-in.
    create table(:consents) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:document, :string, null: false)
      add(:version, :integer, null: false)
      add(:accepted_at, :naive_datetime_usec, null: false)
      timestamps(type: :naive_datetime_usec)
    end

    create(index(:consents, [:user_id, :document]))
  end
end
