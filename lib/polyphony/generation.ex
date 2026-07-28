defmodule Polyphony.Generation do
  @moduledoc """
  Turns a built context into a validated `TurnPacket` (§15 slice 3).

  Flow: call the provider → detect refusal → decode JSON → validate against
  `PacketSchema` → on schema failure, append a corrective message and retry a
  bounded number of times (the Instructor-style in-call retry, §12) → return the
  domain packet.

  This module performs the LLM call, so per foundational rule 1 it must only ever
  run **inside an Oban job**, never inside an aggregate or process manager. It
  returns data; the job dispatches the command.

  Errors are tagged for the §12 remediation table so the job/Director can route:

    * `{:refusal, text}`          → retry once on a *different model*, then fail
    * `{:schema_invalid, msg}`    → in-call retries exhausted; fail (don't loop)
    * `{:empty_response, _}`      → transient; job may retry
    * `{:provider, reason}`       → transport/5xx/rate-limit; Oban backoff
  """

  require Logger

  alias Polyphony.LLM.Provider
  alias Polyphony.Generation.PacketSchema

  @max_schema_retries 2

  @doc """
  Generate a `TurnPacket` from chat `messages`.

  Options:

    * `:provider`   — provider module (defaults to `Provider.default/0`); inject
                      a stub in tests
    * `:model`, `:max_tokens`, `:temperature`, `:thinking`, `:extra_body` —
      passed through to the provider
  """
  @spec generate([Provider.message()], keyword()) ::
          {:ok, Polyphony.TurnPacket.t()} | {:error, term()}
  def generate(messages, opts \\ []) do
    provider = Keyword.get(opts, :provider, Provider.default())
    # Hint to structure-aware providers (e.g. the Mock) which shape to emit.
    opts = Keyword.put_new(opts, :response, :turn_packet)
    attempt(provider, messages, opts, @max_schema_retries)
  end

  defp attempt(provider, messages, opts, retries_left) do
    case Polyphony.LLM.call(messages, Keyword.put(opts, :provider, provider)) do
      {:ok, text} ->
        handle_text(provider, messages, opts, retries_left, text)

      {:error, :empty_response} ->
        {:error, {:empty_response, :provider_returned_blank}}

      {:error, reason} ->
        {:error, {:provider, reason}}
    end
  end

  defp handle_text(provider, messages, opts, retries_left, text) do
    cond do
      refusal?(text) ->
        {:error, {:refusal, text}}

      true ->
        case decode_and_validate(text) do
          {:ok, packet} ->
            {:ok, packet}

          {:error, reason} when retries_left > 0 ->
            # Feed the failure back and let the model correct itself (§12).
            corrective = messages ++ correction_messages(text, reason)
            attempt(provider, corrective, opts, retries_left - 1)

          {:error, {:schema_invalid, msg}} ->
            {:error, {:schema_invalid, msg}}

          {:error, {:invalid_json, _}} ->
            {:error, {:schema_invalid, "response was not valid JSON"}}
        end
    end
  end

  defp decode_and_validate(text) do
    case Jason.decode(text) do
      {:ok, data} when is_map(data) ->
        case PacketSchema.parse(data) do
          {:ok, packet} ->
            {:ok, packet}

          {:error, changeset} ->
            {:error, {:schema_invalid, PacketSchema.error_messages(changeset)}}
        end

      {:ok, _non_object} ->
        {:error, {:invalid_json, :not_an_object}}

      {:error, err} ->
        {:error, {:invalid_json, err}}
    end
  end

  defp correction_messages(previous, {:schema_invalid, msg}) do
    [
      %{role: "assistant", content: previous},
      %{
        role: "user",
        content:
          "Your previous response was invalid: #{msg}. " <>
            "Respond ONLY with corrected JSON matching the required schema — no prose, no markdown fences."
      }
    ]
  end

  defp correction_messages(previous, {:invalid_json, _}) do
    [
      %{role: "assistant", content: previous},
      %{
        role: "user",
        content:
          "That was not valid JSON. Respond with ONLY the JSON object, no prose or code fences."
      }
    ]
  end

  # Cheap heuristic refusal detector. DeepInfra adds no filter layer, so a
  # refusal is the *model's* trained behavior — model-swap is the remediation
  # (§12), and refusals are logged distinctly as a signal to change the default.
  @refusal_patterns [
    "i'm sorry, but i can't",
    "i cannot help with that",
    "i can't help with that",
    "i'm not able to help with that",
    "i am unable to assist",
    "as an ai language model"
  ]

  @doc false
  def refusal?(text) when is_binary(text) do
    head = text |> String.trim_leading() |> String.slice(0, 200) |> String.downcase()
    Enum.any?(@refusal_patterns, &String.contains?(head, &1))
  end
end
