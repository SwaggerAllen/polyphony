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

  @doc """
  Mask an address for logging: `a***@example.com`.

  Delivery logs surface in the debug drawer, which renders for anyone who can load a
  page while `DEBUG_DRAWER` is on — it is not admin-gated, and can't be, since its most
  valuable use is diagnosing sign-in while signed out. Enough of the address survives
  to recognise your own; not enough to harvest somebody else's.
  """
  @spec redact(String.t() | term()) :: String.t()
  def redact(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 1) <> "***@" <> domain
      _ -> "***"
    end
  end

  def redact(_), do: "***"
end
