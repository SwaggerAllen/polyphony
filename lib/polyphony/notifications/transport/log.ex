defmodule Polyphony.Notifications.Transport.Log do
  @moduledoc """
  The default email transport (§B4): logs instead of sending, so the sending path is
  exercised offline. Replaced by a real email adapter (Swoosh/SMTP) via config, with
  no change to `Polyphony.Notifications`.
  """
  @behaviour Polyphony.Notifications.Transport

  require Logger

  @impl true
  def deliver_email(to, subject, _body) do
    Logger.info("email → #{to}: #{subject}")
    {:ok, :logged}
  end
end
