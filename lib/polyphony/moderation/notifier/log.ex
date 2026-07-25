defmodule Polyphony.Moderation.Notifier.Log do
  @moduledoc """
  The default moderation notifier — logs instead of sending (§B3). The one live wire
  in v1 is the admin alert on every new report; real email delivery is B4, which swaps
  in by config without touching the moderation logic.
  """
  @behaviour Polyphony.Moderation.Notifier

  require Logger

  @impl true
  def report_filed(%{id: id, reason: reason}) do
    Logger.info("admin alert: new report ##{id} (#{reason})")
    :ok
  end

  @impl true
  def owner_warned(%{owner_id: owner_id, id: id}, message) do
    Logger.info("owner warning for report ##{id} → user #{owner_id}: #{message}")
    :ok
  end
end
