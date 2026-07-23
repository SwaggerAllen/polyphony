defmodule Polyphony.Authoring.CharacterSheet do
  @moduledoc """
  The authored, portable character layer (§6.1) — a subset sufficient for context
  assembly.

  Two field groups matter to caching (§6.1 "Fact growth is a real problem"):

    * facts flagged `core: true` are **always-resident** — they stay in the frozen
      prefix every scene;
    * the long tail is retrieved per scene against the premise (pgvector) and
      frozen for that scene, never per-turn.

  `initial_knowledge` is what makes dramatic irony work at t=0 (§6.1): the
  visibility projection handles everything during play, but characters must
  *start* knowing different things, and that has to be authored. `relationships`
  are directional (one entry per holder→target).
  """

  defmodule Fact do
    @moduledoc "An atomic true statement about the character (§6.1)."
    @derive Jason.Encoder
    defstruct [:statement, tags: [], concealed: false, core: false]

    @type t :: %__MODULE__{
            statement: String.t(),
            tags: [String.t()],
            concealed: boolean(),
            core: boolean()
          }
  end

  defmodule Relationship do
    @moduledoc "A directional relationship: how `holder` regards `target` (§6.1)."
    @derive Jason.Encoder
    defstruct [:target, :descriptor]
  end

  @derive Jason.Encoder
  defstruct name: nil,
            premise: nil,
            appearance: nil,
            voice: nil,
            temperament: nil,
            backstory: nil,
            initial_knowledge: [],
            facts: [],
            relationships: []

  @type t :: %__MODULE__{}

  @doc "The facts flagged always-resident (§6.1)."
  @spec core_facts(t()) :: [Fact.t()]
  def core_facts(%__MODULE__{facts: facts}), do: Enum.filter(facts, & &1.core)

  @doc "The long-tail facts — retrieval candidates against the scene premise."
  @spec long_tail_facts(t()) :: [Fact.t()]
  def long_tail_facts(%__MODULE__{facts: facts}), do: Enum.reject(facts, & &1.core)
end
