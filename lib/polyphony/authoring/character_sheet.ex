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

  defmodule Boundary do
    @moduledoc """
    A characterization limit (§A3, FS V4.6) — how the character holds a `topic`
    (romance, violence, betrayal…). **Not a content filter:** a boundary produces a
    refusal *in the character's voice*, generated like any other beat, never a
    post-generation block. `on_pressure` is the in-character reaction when pushed.

      * `:open`        — no gate.
      * `:closed`      — a hard line; refusal in character.
      * `:conditional` — held until `condition` is met by the campaign's canon arc,
        which the Director evaluates (`Polyphony.Authoring.BoundaryGate`). Its
        composition with the arc layer is what makes slow burn mechanically real —
        the boundary holds until the story earns it, not a prompt hint the model
        forgets.

    `category` (§A5) is an **optional** link to a content-governance bucket
    (`:sexual | :graphic_violence | :other`). It does not conflate the layers — the
    boundary is still pure characterization (stance, condition, on_pressure). The
    category only lets the campaign ceiling *cap* this boundary: a boundary in a
    category the campaign disabled is forced closed at assembly (`Polyphony.Content`).
    A pure-characterization boundary leaves it `nil` and the register never touches it.
    """
    @derive Jason.Encoder
    defstruct [:topic, :stance, :condition, :on_pressure, :category]

    @type stance :: :open | :conditional | :closed
    @type t :: %__MODULE__{
            topic: String.t(),
            stance: stance(),
            condition: String.t() | nil,
            on_pressure: String.t() | nil,
            category: Polyphony.Content.category() | nil
          }
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
            relationships: [],
            boundaries: [],
            # §B8: `:stub` is a name + one-line `role` + inbound `relationships`, with no
            # generated sheet yet; promotion fills the sheet and gates it `:proposed`
            # before it becomes `:full` (mirrors locations' `origin: :discovered`).
            status: :full,
            role: nil

  @type status :: :stub | :proposed | :full
  @type t :: %__MODULE__{}

  @doc "The facts flagged always-resident (§6.1)."
  @spec core_facts(t()) :: [Fact.t()]
  def core_facts(%__MODULE__{facts: facts}), do: Enum.filter(facts, & &1.core)

  @doc "The long-tail facts — retrieval candidates against the scene premise."
  @spec long_tail_facts(t()) :: [Fact.t()]
  def long_tail_facts(%__MODULE__{facts: facts}), do: Enum.reject(facts, & &1.core)
end
