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
  alias PolyphonyCore.Content

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

  # ── The content ceiling, applied to a boundary ──────────────────────────────
  #
  # These two moved off `Content` so the core can be a leaf: they are the only thing in
  # it that had to know the shape of a `CharacterSheet.Boundary`, and a struct
  # dependency is still a dependency. Here they sit next to `resolve/3`, which is what
  # runs immediately after them — the ceiling caps, then the gate releases.

  @doc """
  Cap a boundary by the register (layer 2 constrains layer 3). One whose `:category`
  the register disables is **capped toward refusal** — the campaign ceiling overrides
  characterization, so an `:open` stance can't reopen disabled content. One with no
  category is characterization and passes through untouched.

  **Toward refusal, not merely `:closed`.** For a refusal those are the same thing:
  forced closed means she won't. For a **compulsion** they are opposites — a closed
  compulsion is one she always acts on — so capping it also flips its direction, and
  the item becomes a hard line against the same topic. `ux/polyphony-character.html`
  §05 states the rule and why: *a compulsion flagged for content the campaign doesn't
  allow is held closed, meaning she doesn't do it. That's the correct direction to
  fail in.* A cap that only set `stance: :closed` would make the ceiling compel the
  content it exists to forbid.

  Applied at context assembly, before `BoundaryGate.resolve/3`, so a gated-off
  category never releases regardless of arc or stance.
  """
  @spec gate_boundary(Boundary.t(), [Content.category()]) :: Boundary.t()
  def gate_boundary(%Boundary{category: category} = boundary, register) do
    if Content.permits?(register, category), do: boundary, else: cap(boundary)
  end

  @doc """
  Authoring-time constraint (FS §V8a): the same rule surfaced for the boundary
  editor. Returns `{:ok, boundary}` when the category is permitted, or
  `{:constrained, capped}` when the campaign ceiling forbids it — the editor must not
  let an author open a boundary past the ceiling. Caps identically to
  `gate_boundary/2`, direction included.
  """
  @spec constrain_boundary(Boundary.t(), [Content.category()]) ::
          {:ok, Boundary.t()} | {:constrained, Boundary.t()}
  def constrain_boundary(%Boundary{category: category} = boundary, register) do
    if Content.permits?(register, category),
      do: {:ok, boundary},
      else: {:constrained, cap(boundary)}
  end

  # Held, and held as a refusal — so the capped item always means "they don't".
  defp cap(%Boundary{} = boundary),
    do: %Boundary{boundary | stance: :closed, direction: :refusal}
end
