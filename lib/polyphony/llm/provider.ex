defmodule Polyphony.LLM.Provider do
  @moduledoc """
  The provider adapter boundary (§2).

  Everything above this line is provider-agnostic; a single behaviour callback
  is the entire surface a provider must implement. This is the seam the brief
  insists on keeping thin "so local can return later" — a local/GPU adapter, a
  policy-aware fallback router, or a swap from `:httpc` to ReqLLM are all just
  another module implementing `complete/2`.

  A provider returns the assistant's **raw text** (expected to be JSON when a
  schema was requested). Parsing, schema validation, and retry classification
  live above it in `Polyphony.Generation` — the provider stays unopinionated.
  """

  @typedoc "An OpenAI-style chat message."
  @type message :: %{role: String.t(), content: String.t()}

  @typedoc """
  Call options. Recognized keys (adapter-dependent):

    * `:model`        — model id (defaults to the configured workhorse)
    * `:max_tokens`   — hard cap; always set (§3 "hard-cap max_tokens everywhere")
    * `:temperature`  — sampling temperature
    * `:thinking`     — whether to allow reasoning tokens (default false on the
                        volume path, §3); enable only for Director/generation
    * `:extra_body`   — provider-specific body fields merged last
  """
  @type opts :: keyword()

  @callback complete(messages :: [message()], opts()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "The configured default provider module."
  @spec default() :: module()
  def default do
    Application.get_env(:polyphony, :llm, [])
    |> Keyword.get(:provider, Polyphony.LLM.DeepInfra)
  end
end
