defmodule Polyphony.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    # The sent-notification log (§B4): a record of what the sending path delivered
    # (or skipped), so history and delivery status have a home. Email is the only
    # channel in v1.
    create table(:notifications) do
      add(:recipient_id, references(:users, on_delete: :nilify_all))
      add(:recipient_email, :string)
      add(:type, :string, null: false)
      add(:channel, :string, null: false, default: "email")
      add(:subject, :string)
      add(:body, :text)
      add(:status, :string, null: false, default: "sent")
      add(:sent_at, :naive_datetime_usec)
      timestamps(type: :naive_datetime_usec, updated_at: false)
    end

    create(index(:notifications, [:recipient_id]))
    create(index(:notifications, [:type]))

    # Per-user notification preferences (§B4, mostly stubs): opt-out model — a row
    # exists only for a type a user has turned OFF. Safety-critical types (admin
    # report alerts) are delivered with `force:` and bypass this.
    create table(:notification_prefs) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:type, :string, null: false)
      add(:enabled, :boolean, null: false, default: true)
      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:notification_prefs, [:user_id, :type]))
  end
end
