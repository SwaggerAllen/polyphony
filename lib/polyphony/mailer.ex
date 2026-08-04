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

  require Logger

  # Everything gen_smtp will hand back with a credential in it. `:username` is here
  # because for half the providers it *is* the secret — Postmark uses the server token
  # as both fields.
  @secret ~w(password username)a

  # Not sensitive, just enormous: the whole system CA bundle inlined into a log line
  # buries the one fact the line was printed for.
  @bulky ~w(cacerts tls_options sockopts)a

  @doc """
  gen_smtp's `trace_fun` — the SMTP conversation, line by line, into the log.

  Armed by `SMTP_TRACE=true` and off otherwise. It exists because gen_smtp reports a
  refused send as a single word — `:closed`, `:tls_failed`, `auth_failed` — with no
  indication of how far the conversation got, and "the relay hung up" means something
  entirely different before the banner (the endpoint is refusing us) than after AUTH
  (we are refusing the message). The trace is the only thing that tells them apart,
  and it lands in the debug drawer, so it is readable from a phone.

  **It redacts.** gen_smtp traces `"TLS not requested ~p~n"` with its *entire* options
  proplist, and that carries the password — and that branch fires on exactly the
  implicit-TLS path, where `tls` is `:never`. A trace that leaks the SMTP credentials
  into a log the debug drawer renders would be a worse bug than the one it is
  diagnosing.
  """
  @spec trace(charlist() | String.t(), [term()]) :: :ok
  def trace(format, args), do: Logger.info(trace_line(format, args))

  @doc """
  One trace line, redacted and tagged, as a string.

  Split out from `trace/2` so the redaction can be tested as what it is — a pure
  function of the arguments — rather than through the log, where the assertion would
  depend on the suite's global level and on nothing else having raised it.
  """
  @spec trace_line(charlist() | String.t(), [term()]) :: String.t()
  def trace_line(format, args) do
    message =
      format
      |> :io_lib.format(Enum.map(args, &redact/1))
      |> IO.iodata_to_binary()
      |> String.trim_trailing()

    # `[mail]` is what the debug drawer picks out, which is how this is read from a
    # phone.
    "[mail] smtp: #{message}"
  end

  # Structural rather than top-level: the options proplist turns up nested inside
  # other traced terms, and a redaction that only checks the outermost list would miss
  # it there.
  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact({key, _value}) when key in @secret, do: {key, "[FILTERED]"}
  defp redact({key, _value}) when key in @bulky, do: {key, :...}
  defp redact(term), do: term
end
