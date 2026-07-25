defmodule Polyphony.Repo.Migrations.CreateModeration do
  use Ecto.Migration

  def change do
    # Reports on public/unlisted content (§B3). Reporter auth is required (FK);
    # owner_id is denormalized so a report can grant scoped, audited access to the
    # owning account's content (§C reactive access).
    create table(:reports) do
      add(:reporter_id, references(:users, on_delete: :nilify_all), null: false)
      add(:owner_id, references(:users, on_delete: :nilify_all))
      add(:item_type, :string, null: false)
      add(:item_id, :integer)
      add(:reason, :string, null: false)
      add(:detail, :text)
      add(:status, :string, null: false, default: "open")
      add(:resolution, :string)
      add(:resolution_reason, :text)
      add(:resolved_by_id, references(:users, on_delete: :nilify_all))
      add(:resolved_at, :naive_datetime_usec)
      timestamps(type: :naive_datetime_usec)
    end

    create(index(:reports, [:status]))
    create(index(:reports, [:owner_id]))

    # The admin audit log (§B3): every admin action, especially any access to user
    # content, logged and attributed. A data-layer requirement, never UI-only.
    create table(:admin_audit_logs) do
      add(:actor_id, references(:users, on_delete: :nilify_all), null: false)
      add(:action, :string, null: false)
      add(:target_type, :string)
      add(:target_id, :integer)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create(index(:admin_audit_logs, [:actor_id]))
    create(index(:admin_audit_logs, [:target_type, :target_id]))

    # Moderation state on the account (§B3): suspension gates login (web layer);
    # a review flag is raised by an absolute-line takedown — the account, not just
    # the item.
    alter table(:users) do
      add(:suspended_at, :naive_datetime_usec)
      add(:flagged_for_review_at, :naive_datetime_usec)
    end
  end
end
