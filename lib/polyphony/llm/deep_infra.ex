defmodule Polyphony.LLM.DeepInfra do
  @moduledoc """
  DeepInfra provider adapter — direct, OpenAI-compatible (§2, §3).

  DeepInfra was chosen for its permissive terms (§3); this adapter talks to its
  OpenAI-compatible endpoint. It bakes in the model-configuration cautions from
  the brief:

    * **Thinking off on the volume path.** Reasoning tokens bill as (expensive)
      output and can run away; disabled unless `thinking: true` is passed
      (Director routing / character-world generation).
    * **`max_tokens` hard-capped, always.** Defaults applied here if absent.
    * **Read the response field directly.** Qwen3.5 has been observed returning
      empty responses; an empty `content` is surfaced as `{:error, :empty_response}`
      so the caller can retry rather than commit a blank packet.

  Uses Erlang's built-in `:httpc` rather than an external HTTP client — the
  provider behaviour keeps the choice swappable, and this avoids dragging in an
  HTTP/2 stack that this toolchain can't compile safely.
  """
  @behaviour Polyphony.LLM.Provider

  require Logger

  @default_max_tokens 1024
  @default_path "/v1/openai/chat/completions"

  @impl true
  def complete(messages, opts \\ []) do
    cfg = config()
    model = Keyword.get(opts, :model) || cfg[:model] || raise("no model configured")

    body =
      %{
        model: model,
        messages: messages,
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        temperature: Keyword.get(opts, :temperature, 0.8),
        stream: false
      }
      |> put_thinking(Keyword.get(opts, :thinking, false))
      |> Map.merge(Map.new(Keyword.get(opts, :extra_body, [])))

    with {:ok, json} <- post(cfg, body),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, content} <- extract_content(decoded) do
      {:ok, content}
    end
  end

  # Qwen3.5 ships thinking on; the OpenAI-compatible way to turn it off is the
  # chat-template kwarg. Enabling it is a no-op flag here (the model default).
  defp put_thinking(body, true), do: body

  defp put_thinking(body, false),
    do: Map.put(body, :chat_template_kwargs, %{enable_thinking: false})

  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) and content != "",
       do: {:ok, content}

  defp extract_content(%{"choices" => [%{"message" => %{"content" => ""}} | _]}),
    do: {:error, :empty_response}

  defp extract_content(other), do: {:error, {:unexpected_response, other}}

  defp post(cfg, body) do
    url = String.to_charlist((cfg[:base_url] || "https://api.deepinfra.com") <> @default_path)
    api_key = cfg[:api_key] || System.get_env("DEEPINFRA_API_KEY") || ""

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"accept", ~c"application/json"}
    ]

    request = {url, headers, ~c"application/json", Jason.encode!(body)}
    http_opts = [timeout: cfg[:timeout] || 60_000, ssl: ssl_opts(cfg)]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, resp}} ->
        {:ok, resp}

      {:ok, {{_v, status, _r}, _h, resp}} ->
        {:error, {:http_status, status, resp}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # Verify against the proxy/system CA bundle when one is configured; the agent
  # proxy sets SSL_CERT_FILE. Falls back to OTP's built-in CA store.
  defp ssl_opts(cfg) do
    cacert = cfg[:cacertfile] || System.get_env("SSL_CERT_FILE")

    base = [verify: :verify_peer, depth: 3, customize_hostname_check: [match_fun: &hostname_ok/2]]

    cond do
      is_binary(cacert) and cacert != "" ->
        [{:cacertfile, String.to_charlist(cacert)} | base]

      function_exported?(:public_key, :cacerts_get, 0) ->
        [{:cacerts, :public_key.cacerts_get()} | base]

      true ->
        [verify: :verify_none]
    end
  end

  # Delegate to the default wildcard-aware hostname check.
  defp hostname_ok(ref, actual),
    do: :public_key.pkix_verify_hostname_match_fun(:https).(ref, actual)

  defp config do
    Application.get_env(:polyphony, :llm, [])
    |> Keyword.get(:deepinfra, [])
  end
end
