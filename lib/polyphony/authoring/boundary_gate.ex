defmodule Polyphony.Authoring.BoundaryGate do
  @moduledoc """
  Resolves a character's boundaries (§A3) against the campaign's **canon arc**.

  A boundary is characterization, not a safety filter (§V4.6): the resolved state
  is fed to the character's context so the model generates a refusal *in voice*,
  never a post-generation block. Each boundary resolves to `released: true | false`:

    * `:open`        — always released (no gate).
    * `:closed`      — never released (a hard line).
    * `:conditional` — released once `condition` is met by the canon arc. That
      judgment is the real work: an LLM decides whether the accumulated canon facts
      satisfy the condition. It's evaluated at **scene open** (the context assembler
      calls this), never per beat — arc only changes at scene close, so the resolved
      state is stable for the life of the scene and re-derived the next one.

  The evaluator is pluggable via `:evaluator` — a `(condition, canon_statements) ->
  boolean` function or a module with `met?/3` — defaulting to the LLM. It **fails
  closed**: an unjudgeable condition leaves the boundary held (the character stays
  guarded), which is the safe default for slow burn.
  """

  alias Polyphony.Authoring.CharacterSheet.Boundary

  defmodule Evaluator do
    @moduledoc "Judges whether a conditional boundary's condition is met by canon arc (§A3)."
    @callback met?(condition :: String.t(), canon_statements :: [String.t()], opts :: keyword()) ::
                boolean()
  end

  @type resolved :: %{boundary: Boundary.t(), released: boolean()}

  @doc "Resolve `boundaries` against `canon_arc` (a list of arc entries; only canon counts)."
  @spec resolve([Boundary.t()], [map()], keyword()) :: [resolved()]
  def resolve(boundaries, canon_arc \\ [], opts \\ [])

  def resolve(boundaries, canon_arc, opts) when is_list(boundaries) do
    statements = canon_statements(canon_arc)
    Enum.map(boundaries, &resolve_one(&1, statements, opts))
  end

  defp resolve_one(%Boundary{stance: :open} = b, _statements, _opts),
    do: %{boundary: b, released: true}

  defp resolve_one(%Boundary{stance: :closed} = b, _statements, _opts),
    do: %{boundary: b, released: false}

  defp resolve_one(%Boundary{stance: :conditional, condition: condition} = b, statements, opts) do
    released = condition not in [nil, ""] and met?(condition, statements, opts)
    %{boundary: b, released: released}
  end

  # Unknown/nil stance → treat as held (safe default).
  defp resolve_one(%Boundary{} = b, _statements, _opts), do: %{boundary: b, released: false}

  defp met?(condition, statements, opts) do
    case Keyword.get(opts, :evaluator) do
      fun when is_function(fun, 2) -> fun.(condition, statements)
      mod when is_atom(mod) and not is_nil(mod) -> mod.met?(condition, statements, opts)
      nil -> __MODULE__.LLMEvaluator.met?(condition, statements, opts)
    end
  end

  # Canon statements the condition is judged against (only reviewed canon applies).
  defp canon_statements(canon_arc) do
    for e <- canon_arc, to_string(Map.get(e, :status)) == "canon", do: Map.get(e, :statement)
  end

  defmodule LLMEvaluator do
    @moduledoc "Judges a conditional boundary's `condition` against canon arc via the LLM. Fails closed."
    @behaviour Polyphony.Authoring.BoundaryGate.Evaluator

    alias Polyphony.LLM.Provider

    @impl true
    def met?(condition, statements, opts) do
      provider = Keyword.get(opts, :provider) || Provider.default()

      facts =
        if statements == [], do: "(none yet)", else: Enum.map_join(statements, "\n", &"- #{&1}")

      messages = [
        %{
          role: "system",
          content:
            "Decide whether a story condition has been met by the established canon " <>
              "facts. Reply with only \"yes\" or \"no\"."
        },
        %{role: "user", content: "Canon so far:\n#{facts}\n\nCondition: #{condition}\n\nMet?"}
      ]

      case Polyphony.LLM.call(
             messages,
             [provider: provider, response: :gate, model: Keyword.get(opts, :model)] ++
               Keyword.take(opts, [:user_id, :campaign_id, :usage_kind])
           ) do
        {:ok, text} -> yes?(text)
        _ -> false
      end
    end

    defp yes?(text),
      do: text |> to_string() |> String.trim() |> String.downcase() |> String.starts_with?("yes")
  end
end
