defmodule Polyphony.Notifications.ModerationNotifier do
  @moduledoc """
  Routes §B3 moderation notifications through the §B4 sending path — the adapter that
  makes the one live notification wire (admin report alerts) actually send. A new
  report fans out to every admin (`force:`d past preferences, since it is safety
  work); an owner warning delivers to the reported account.

  Wire it in with `config :polyphony, :moderation_notifier,
  Polyphony.Notifications.ModerationNotifier`.
  """
  @behaviour Polyphony.Moderation.Notifier

  alias Polyphony.Notifications

  @impl true
  def report_filed(report) do
    Notifications.notify_admins(:report_alert, %{report_id: report.id, reason: report.reason})
    :ok
  end

  @impl true
  def owner_warned(%{owner_id: owner_id} = report, message) when not is_nil(owner_id) do
    Notifications.deliver(owner_id, :owner_warning, %{message: message, report_id: report.id})
    :ok
  end

  def owner_warned(_report, _message), do: :ok
end
