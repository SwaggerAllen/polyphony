defmodule Polyphony.Moderation.Notifier do
  @moduledoc """
  The moderation notification boundary (§B3). v1's one live notification wire is the
  **admin email alert on every new report**; the owner-warning path rides the same
  seam. Actual sending is B4 infrastructure, so this is a pluggable behaviour with a
  logging default — the wire exists and is tested offline, and B4 swaps in email
  without touching the moderation logic.

  Select the adapter with `config :polyphony, :moderation_notifier, MyAdapter`, or
  pass `notifier:` in opts (tests capture with a stub).
  """

  alias Polyphony.Moderation.Report

  @callback report_filed(Report.t()) :: :ok
  @callback owner_warned(Report.t(), message :: String.t()) :: :ok

  @doc "The configured notifier adapter (default: the logging one)."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:polyphony, :moderation_notifier, __MODULE__.Log)
end
