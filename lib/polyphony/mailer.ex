defmodule Polyphony.Mailer do
  @moduledoc """
  The Swoosh mailer (§B4). Configuration is entirely runtime — see
  `config/runtime.exs` — so the adapter and credentials are deploy-time facts rather
  than compile-time ones, and a build artifact carries no mail config at all.

  Nothing in the app calls this directly. `Polyphony.Notifications` speaks to the
  `Polyphony.Notifications.Transport` behaviour, and `Transport.Email` is the one
  implementation that lands here — so the notification path stays testable offline and
  a mailer misconfiguration can't reach the domain.
  """
  use Swoosh.Mailer, otp_app: :polyphony
end
