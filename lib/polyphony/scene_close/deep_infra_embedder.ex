defmodule Polyphony.SceneClose.DeepInfraEmbedder do
  @moduledoc """
  The production embedder (§8) — DeepInfra's OpenAI-compatible `/v1/openai/embeddings`
  endpoint.

  Selected in prod via `config :polyphony, :embedder, __MODULE__`; dev/test keep the
  offline `MockEmbedder`. The model id is env-driven (`DEEPINFRA_EMBED_MODEL`,
  default `BAAI/bge-large-en-v1.5`) — 1024-dim, matching the
  `character_scene_summaries.embedding` column. A different-dimension model is a
  migration. Connection config (base URL, API key, CA bundle) is shared with the chat
  adapter under `:llm, :deepinfra`.

  Uses Erlang's `:httpc` (like `Polyphony.LLM.DeepInfra`) to avoid dragging in an
  HTTP/2 stack this toolchain can't compile safely. Every caller of `embed/1` already
  treats `{:error, _}` as "no vector" and degrades (a missing summary is survivable,
  §12), so transport failures never crash a scene close or a retrieval.
  """
  @behaviour Polyphony.SceneClose.Embedder

  @default_model "BAAI/bge-large-en-v1.5"
  @path "/v1/openai/embeddings"

  @impl true
  def embed(text) when is_binary(text) do
    cfg = config()
    body = %{model: model(cfg), input: text, encoding_format: "float"}

    with {:ok, json} <- post(cfg, body),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, vector} <- extract_embedding(decoded) do
      {:ok, vector}
    end
  end

  # OpenAI-compatible embeddings shape: %{"data" => [%{"embedding" => [floats]}]}.
  @doc false
  def extract_embedding(%{"data" => [%{"embedding" => vector} | _]})
      when is_list(vector) and vector != [],
      do: {:ok, vector}

  def extract_embedding(other), do: {:error, {:unexpected_response, other}}

  defp model(cfg),
    do: cfg[:embed_model] || System.get_env("DEEPINFRA_EMBED_MODEL") || @default_model

  # ── Transport (mirrors Polyphony.LLM.DeepInfra) ──────────────────────────────

  defp post(cfg, body) do
    url = String.to_charlist((cfg[:base_url] || "https://api.deepinfra.com") <> @path)
    api_key = cfg[:api_key] || System.get_env("DEEPINFRA_API_KEY") || ""

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)},
      {~c"accept", ~c"application/json"}
    ]

    request = {url, headers, ~c"application/json", Jason.encode!(body)}
    http_opts = [timeout: cfg[:timeout] || 60_000, ssl: ssl_opts(cfg)]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, resp}} -> {:ok, resp}
      {:ok, {{_v, status, _r}, _h, resp}} -> {:error, {:http_status, status, resp}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

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

  defp hostname_ok(ref, actual),
    do: :public_key.pkix_verify_hostname_match_fun(:https).(ref, actual)

  defp config do
    Application.get_env(:polyphony, :llm, [])
    |> Keyword.get(:deepinfra, [])
  end
end
