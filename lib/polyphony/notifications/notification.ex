defmodule Polyphony.Notifications.Notification do
  @moduledoc """
  A sent-notification record (§B4): what the sending path delivered or skipped, with
  status, so delivery history has a home. Email is the only channel in v1.
  """
  use Ecto.Schema
  import Ecto.Query

  schema "notifications" do
    field(:recipient_id, :id)
    field(:recipient_email, :string)
    field(:type, :string)
    field(:channel, :string, default: "email")
    field(:subject, :string)
    field(:body, :string)
    field(:status, :string, default: "sent")
    field(:sent_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec, updated_at: false)
  end

  def put(repo, attrs), do: repo.insert!(struct(__MODULE__, attrs))

  @doc "A recipient's notification history, newest first."
  def list_for_recipient(repo, recipient_id) do
    repo.all(
      from(n in __MODULE__,
        where: n.recipient_id == ^recipient_id,
        order_by: [desc: n.inserted_at]
      )
    )
  end
end
