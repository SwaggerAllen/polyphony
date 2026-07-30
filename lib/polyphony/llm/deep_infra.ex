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
    body = build_body(messages, opts, cfg)
    model = body.model

    case post(cfg, body) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, decoded} ->
            case extract_content(decoded) do
              {:ok, content} ->
                {:ok, content}

              {:error, reason} = err ->
                log_bad_response(model, body, decoded, reason)
                err
            end

          {:error, reason} ->
            Logger.warning(
              "[deepinfra] non-JSON response model=#{model}: #{String.slice(json, 0, 400)}"
            )

            {:error, reason}
        end

      {:error, {:http_status, status, resp}} = err ->
        Logger.warning(
          "[deepinfra] HTTP #{status} model=#{model}: #{String.slice(to_string(resp), 0, 400)}"
        )

        err

      {:error, {:transport, reason}} = err ->
        Logger.warning("[deepinfra] transport error model=#{model}: #{inspect(reason)}")
        err
    end
  end

  @doc false
  # The request body sent to the chat endpoint. Public for testing the JSON-mode /
  # thinking / token-budget wiring without a network round-trip.
  def build_body(messages, opts, cfg \\ config()) do
    model = Keyword.get(opts, :model) || cfg[:model] || raise("no model configured")

    %{
      model: model,
      messages: messages,
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      temperature: Keyword.get(opts, :temperature, 0.8),
      stream: false
    }
    |> put_thinking(Keyword.get(opts, :thinking, false))
    |> put_response_format(Keyword.get(opts, :response))
    |> put_service_tier(Keyword.get(opts, :service_tier))
    |> Map.merge(Map.new(Keyword.get(opts, :extra_body, [])))
  end

  # The diagnostic log for an empty/malformed model response: the fields that reveal
  # *why* — finish_reason ("length" ⇒ truncated by max_tokens), usage (tokens actually
  # produced), whether thinking was disabled, the cap sent, and the message object
  # itself (an empty `content`, or a stray `reasoning`/other field).
  defp log_bad_response(model, body, decoded, reason) do
    choice = decoded |> Map.get("choices", []) |> List.first() || %{}

    Logger.warning(
      "[deepinfra] bad response model=#{model} reason=#{inspect(reason)} " <>
        "finish_reason=#{inspect(choice["finish_reason"])} usage=#{inspect(decoded["usage"])} " <>
        "sent_thinking=#{inspect(Map.get(body, :chat_template_kwargs))} sent_max_tokens=#{body.max_tokens} " <>
        "message=#{inspect(choice["message"], limit: 30, printable_limit: 600)}"
    )
  end

  # Qwen3.5 ships thinking on; the OpenAI-compatible way to turn it off is the
  # chat-template kwarg. Enabling it is a no-op flag here (the model default).
  defp put_thinking(body, true), do: body

  defp put_thinking(body, false),
    do: Map.put(body, :chat_template_kwargs, %{enable_thinking: false})

  # Response tags whose reply is a JSON **object** we parse (Director decision, character
  # TurnPacket, structured authoring). For these, force OpenAI-compatible JSON mode so the
  # model can't free-form markdown/prose. Prose tags (`:field` — a regenerated sheet
  # paragraph) must NOT be forced into JSON, or the model wraps the paragraph in an object
  # (e.g. `{"thought_process": …}`) to satisfy the format, and the field fills with junk.
  @json_responses ~w(decision turn_packet autofill sheet relationships reciprocals mentions boundaries)a

  defp put_response_format(body, tag) when tag in @json_responses,
    do: Map.put(body, :response_format, %{type: "json_object"})

  defp put_response_format(body, _tag), do: body

  # DeepInfra service tiers schedule the request: `priority` jumps ahead of standard
  # traffic (faster TTFT during peak demand, avoiding `engine_overloaded`) at 1.5×;
  # `flex` is cheaper (0.8×) but slower/occasionally unavailable. Unset ⇒ the field is
  # omitted and DeepInfra uses `standard`. A campaign choice, resolved per beat.
  defp put_service_tier(body, tier) when tier in ["priority", "flex", "standard"],
    do: Map.put(body, :service_tier, tier)

  defp put_service_tier(body, _), do: body

  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) and content != "",
       do: {:ok, content}

  defp extract_content(%{"choices" => [%{"message" => %{"content" => ""}} | _]}),
    do: {:error, :empty_response}

  defp extract_content(other), do: {:error, {:unexpected_response, other}}

  # DeepInfra 429s with `engine_overloaded` ("Model busy, retry later") and times out
  # under load. Those are transient, so retry with exponential backoff before failing
  # the beat. Runs in the (background) generation job, so a few seconds of sleep is fine.
  # `:max_retries` / `:retry_base_ms` are config-tunable.
  defp post(cfg, body), do: with_retry(cfg, fn -> request(cfg, body) end)

  @doc false
  # The retry loop, over an injectable request thunk (so it's testable without a socket).
  def with_retry(cfg, request_fun, attempt \\ 0) do
    case request_fun.() do
      {:ok, resp} ->
        {:ok, resp}

      {:error, reason} = err ->
        max = cfg[:max_retries] || 3

        if attempt < max and transient?(reason) do
          delay = (cfg[:retry_base_ms] || 1000) * Integer.pow(2, attempt)

          Logger.info(
            "[deepinfra] #{transient_label(reason)}; retry #{attempt + 1}/#{max} in #{delay}ms"
          )

          if delay > 0, do: Process.sleep(delay)
          with_retry(cfg, request_fun, attempt + 1)
        else
          err
        end
    end
  end

  @doc false
  # 429 (rate limit / overloaded) and 5xx are transient; so are transport failures
  # (timeout, connection reset). A 4xx that isn't 429 is a real request error — no retry.
  def transient?({:http_status, status, _}), do: status == 429 or status >= 500
  def transient?({:transport, _}), do: true
  def transient?(_), do: false

  defp transient_label({:http_status, status, _}), do: "HTTP #{status}"
  defp transient_label({:transport, reason}), do: "transport #{inspect(reason)}"

  defp request(cfg, body) do
    url = String.to_charlist((cfg[:base_url] || "https://api.deepinfra.com") <> @default_path)
    api_key = cfg[:api_key] || System.get_env("DEEPINFRA_API_KEY") || ""

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"accept", ~c"application/json"}
    ]

    http_request = {url, headers, ~c"application/json", Jason.encode!(body)}
    http_opts = [timeout: cfg[:timeout] || 60_000, ssl: ssl_opts(cfg)]

    case :httpc.request(:post, http_request, http_opts, body_format: :binary) do
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
