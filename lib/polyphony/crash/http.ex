defmodule Polyphony.Crash.HTTP do
  @moduledoc """
  The one HTTP request the crash reporter makes, over Erlang's own `:httpc`.

  Sentry defaults to Finch and **refuses to boot** without it, so a client has to be
  chosen deliberately either way. This is `:httpc` for the same reason
  `Polyphony.LLM.DeepInfra` is: the standard library already ships an HTTP client, and
  the alternative is four packages and a supervision tree so that a crash reporter can
  send one POST. `child_spec/0` is optional in the behaviour precisely so a client with
  nothing to supervise can decline, which this one does.

  TLS verification is the same setup the provider adapter uses, and it matters more
  here than there: this connection carries an error payload off the box, so a silently
  unverified peer would be a crash report handed to whoever answered.

  **Failures are returned, never raised.** Sentry logs a dropped event and carries on,
  and that is the only acceptable behaviour for this module — a reporter that can take
  the request down with it converts every outage at a third party into an outage here.
  """
  @behaviour Sentry.HTTPClient

  @timeout 8_000

  @impl true
  def post(url, headers, body) do
    request = {String.to_charlist(url), charlist_headers(headers), ~c"application/json", body}

    options = [
      timeout: @timeout,
      connect_timeout: @timeout,
      ssl: ssl_options()
    ]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, string_headers(response_headers), response_body}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # `:httpc` raises on a URL it cannot parse, and a malformed DSN is a configuration
    # mistake rather than a reason to lose the report *and* the process reporting it.
    e -> {:error, e}
  end

  defp charlist_headers(headers),
    do: for({k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)})

  defp string_headers(headers),
    do: for({k, v} <- headers, do: {List.to_string(k), List.to_string(v)})

  # Lifted from the provider adapter rather than re-derived: `verify_peer` with the
  # OTP-provided CA store, falling back to `SSL_CERT_FILE` when the environment names
  # one (which is how this sandbox's proxy CA bundle is supplied).
  defp ssl_options do
    base = [verify: :verify_peer, depth: 3, customize_hostname_check: [match_fun: &hostname_ok/2]]

    case System.get_env("SSL_CERT_FILE") do
      path when is_binary(path) and path != "" ->
        [{:cacertfile, String.to_charlist(path)} | base]

      _ ->
        [{:cacerts, :public_key.cacerts_get()} | base]
    end
  end

  defp hostname_ok(ref, actual),
    do: :public_key.pkix_verify_hostname_match_fun(:https).(ref, actual)
end
