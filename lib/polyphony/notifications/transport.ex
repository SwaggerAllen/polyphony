defmodule Polyphony.Notifications.Transport do
  @moduledoc """
  The notification transport seam (§B4). v1 is **email only**. Real delivery (Swoosh /
  SMTP) is a later swap; the default adapter logs, so the whole sending path runs and
  is tested offline — no egress. Select with
  `config :polyphony, :notification_transport, MyAdapter` or `transport:` in opts.
  """

  @callback deliver_email(to :: String.t(), subject :: String.t(), body :: String.t()) ::
              {:ok, term()} | {:error, term()}

  @doc "The configured transport adapter (default: the logging one)."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:polyphony, :notification_transport, __MODULE__.Log)
end
