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
    @moduledoc """
    A directional relationship: how `holder` regards `target` (§6.1). `descriptor`
    is the holder→target regard; `reciprocal` optionally records the target→holder
    regard (usually asymmetrical — a "mentor" is regarded back as a "student"). The
    reciprocal is authoring metadata, populated when a stub is seeded from another
    character's relationship so the stub carries both sides.

    `target` is a display name; `target_id` is the stable library id of the character
    it refers to (set once that character exists — an existing pick or a seeded stub).
    Resolution goes through `target_id` so a rename never breaks the link; `target` is
    for display and for stubbing a not-yet-created name.
    """
    @derive Jason.Encoder
    defstruct [:target, :target_id, :descriptor, :reciprocal]
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

    @doc """
    Build a boundary from a string-keyed map (the shape `Autofill.suggest_boundaries`
    returns and the editor form submits): `topic`, `stance`, `condition`, `on_pressure`,
    `category`. Unknown/blank stance ⇒ `:closed`; unknown/blank category ⇒ `nil`; blank
    condition / on_pressure ⇒ `nil`. Shared by the sheet editor and Quick Build so the
    AI-suggested and hand-entered paths stay in lockstep.
    """
    @spec from_map(map()) :: t()
    def from_map(m) when is_map(m) do
      %__MODULE__{
        topic: String.trim(to_string(m["topic"] || m[:topic] || "")),
        stance: parse_stance(m["stance"] || m[:stance]),
        condition: blank_to_nil(m["condition"] || m[:condition]),
        on_pressure: blank_to_nil(m["on_pressure"] || m[:on_pressure]),
        category: parse_category(m["category"] || m[:category])
      }
    end

    defp parse_stance("open"), do: :open
    defp parse_stance("conditional"), do: :conditional
    defp parse_stance(_), do: :closed

    defp parse_category("sexual"), do: :sexual
    defp parse_category("graphic_violence"), do: :graphic_violence
    defp parse_category("other"), do: :other
    defp parse_category(_), do: nil

    defp blank_to_nil(v) do
      case String.trim(to_string(v || "")) do
        "" -> nil
        s -> s
      end
    end
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
            role: nil,
            # The character's **voice colour**, as a slot in the design kit's palette
            # (`--v1`…`--v8`) — distinct from `voice` above, which is prose about how
            # they speak. Assigned once, at creation (`Library.put/2`), and stored so
            # it is stable: derived-by-cast-order colours reshuffle every time somebody
            # is added or removed, and the kit's rule is that a character is the same
            # hue in the transcript, the strip, the cast list, the picker and their own
            # sheet. Stored also means an author can choose it later.
            hue: nil,
            # Optional authoring link to a `world_bible` Library entry (§15): when set,
            # it seeds character auto-generation (`Authoring.Autofill`) so backstory and
            # voice fit the setting. Purely an authoring aid — nil for a world-less sheet.
            world_bible_id: nil

  @type status :: :stub | :proposed | :full
  @type t :: %__MODULE__{}

  # How many voice colours the design kit defines (`--v1`…`--v8`). It lives here
  # rather than in the web layer because assigning a hue is a property of creating a
  # character, and the domain shouldn't reach up into `PolyphonyWeb` to find out how
  # many there are. `PolyphonyWeb.Voice` reads this back.
  @hue_count 8

  @doc "How many distinct voice colours exist before the palette wraps."
  @spec hue_count() :: pos_integer()
  def hue_count, do: @hue_count

  @doc "The facts flagged always-resident (§6.1)."
  @spec core_facts(t()) :: [Fact.t()]
  def core_facts(%__MODULE__{facts: facts}), do: Enum.filter(facts, & &1.core)

  @doc "The long-tail facts — retrieval candidates against the scene premise."
  @spec long_tail_facts(t()) :: [Fact.t()]
  def long_tail_facts(%__MODULE__{facts: facts}), do: Enum.reject(facts, & &1.core)
end
