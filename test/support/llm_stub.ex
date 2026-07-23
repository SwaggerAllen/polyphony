defmodule Polyphony.LLM.Stub do
  @moduledoc """
  Deterministic provider for tests — no network. Lets the generation pipeline
  (parse → validate → retry → dispatch) be exercised end-to-end without a live
  model.

  Response resolution, in order:

    1. `opts[:respond_with]` — `{:ok, text}` | `{:error, term}` | `(messages -> result)`.
       Preferred for async unit tests: no global state.
    2. Application env `[:polyphony, :llm, :stub_response]` — for paths (like the
       Oban job) that resolve the provider from config rather than opts.
    3. A canned, schema-valid `TurnPacket` JSON.
  """
  @behaviour Polyphony.LLM.Provider

  @impl true
  def complete(messages, opts \\ []) do
    case Keyword.get(opts, :respond_with) do
      nil -> from_env_or_default(messages)
      fun when is_function(fun, 1) -> fun.(messages)
      result -> result
    end
  end

  defp from_env_or_default(messages) do
    case Application.get_env(:polyphony, :llm, []) |> Keyword.get(:stub_response) do
      nil -> {:ok, canned_packet_json()}
      fun when is_function(fun, 1) -> fun.(messages)
      result -> result
    end
  end

  @doc "A schema-valid TurnPacket as JSON — an interior thought plus a spoken line."
  def canned_packet_json do
    Jason.encode!(%{
      moves: [
        %{seq: 1, type: "thought", content: "Careful now."},
        %{
          seq: 2,
          type: "speech",
          content: "Good evening.",
          addressed_to: [],
          audibility: "normal"
        }
      ],
      self_state: %{
        mood_felt: "wary",
        demeanor: "gracious",
        intention: "learn why they came",
        position: "near the hearth"
      }
    })
  end

  @doc "A typical model refusal string, for exercising the §12 refusal path."
  def refusal_text,
    do: "I'm sorry, but I can't help with that request."
end
