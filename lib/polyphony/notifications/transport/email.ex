defmodule Polyphony.Notifications.Transport.Email do
  @moduledoc """
  Real email delivery (§B4) — the transport `Transport.Log` was always a placeholder
  for. Builds a plain-text `Swoosh.Email` and hands it to `Polyphony.Mailer`.

  Plain text, no HTML part, deliberately: the only thing v1 sends anyone is a sign-in
  link and a short moderation note. A single-part text/plain message renders
  identically everywhere, can't leak a tracking pixel, and is markedly less likely to
  be filtered as spam than a bare HTML mail with one link in it — which is exactly what
  a magic-link email would otherwise be.

  The `from` address is required and read at send time rather than boot: an
  unconfigured mailer must fail as a *delivery* error that gets recorded on the
  notification row, not as an exception that takes down whatever was sending.
  """
  @behaviour Polyphony.Notifications.Transport

  import Swoosh.Email

  alias Polyphony.Mailer

  @impl true
  def deliver_email(to, subject, body) do
    case from_address() do
      nil ->
        {:error, :no_from_address}

      from ->
        new()
        |> to(to)
        |> from(from)
        |> subject(subject)
        |> text_body(body)
        |> extra_headers()
        |> Mailer.deliver()
    end
  end

  # Provider headers, from config rather than hard-coded, because this transport is
  # SMTP-generic and shouldn't name a vendor. Postmark's `X-PM-Message-Stream` is the
  # concrete case: it routes the message to a stream, and a server whose default isn't
  # the one you meant will accept the mail and deliver it somewhere you aren't looking.
  # Unknown `X-` headers are ignored by every other relay, so this is safe to carry.
  defp extra_headers(email) do
    :polyphony
    |> Application.get_env(:mail_headers, %{})
    |> Enum.reduce(email, fn {name, value}, acc ->
      header(acc, to_string(name), to_string(value))
    end)
  end

  # `{name, address}` when a display name is configured — a sign-in mail from
  # "Polyphony" reads as less suspect than one from a bare address, and it is the
  # cheapest deliverability win available.
  defp from_address do
    case Application.get_env(:polyphony, :mail_from) do
      nil -> nil
      "" -> nil
      address when is_binary(address) -> {mail_from_name(), address}
      {_name, _address} = pair -> pair
    end
  end

  defp mail_from_name, do: Application.get_env(:polyphony, :mail_from_name, "Polyphony")
end
