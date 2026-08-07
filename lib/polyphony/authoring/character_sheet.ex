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
    @moduledoc """
    An atomic true statement about the character (§6.1).

    `concealed` and `core` are orthogonal and are not collapsed: *always in mind* is
    whether **she** carries it every turn, *secret* is who **else** has it. A woman
    can have a secret she never thinks about.

    `audience` says who else starts out knowing a concealed one
    (`Polyphony.Authoring.Audience`). Nobody, by default — and the character it is
    about always knows it, which is why they are never a choice in the picker.
    """
    @derive Jason.Encoder
    defstruct [:statement, :audience, tags: [], concealed: false, core: false]

    @type t :: %__MODULE__{
            statement: String.t(),
            tags: [String.t()],
            concealed: boolean(),
            core: boolean(),
            audience: Polyphony.Authoring.Audience.t() | nil
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
    A place the character can be **pushed** (§A3, FS V4.6) — and the moment it gives.
    **Not a content filter:** it produces a beat *in the character's voice*, generated
    like any other, never a post-generation block.

    ## Two directions, one gate

    `direction` says which way the pressure runs, and it is grouping rather than
    wording — `ux/polyphony-character.html` §05 is explicit that the two are separate
    lists so an item can never be read backwards, which is exactly what went wrong
    when everything was one list of "lines":

      * `:refusal`    — *something she won't do.*
      * `:compulsion` — *something she can't stop doing.* The same gate with the sign
        flipped, and dramatically it is the better half: covering for her father is a
        stronger story engine than any refusal on the sheet.

    `stance` is unchanged by the direction — it only ever answers *does the gate
    hold?* What holding **means** is what flips. A held refusal is "she won't"; a held
    compulsion is "she can't stop". A released refusal is "she will now"; a released
    compulsion is "she has broken it".

      * `:open`        — no gate at all.
      * `:closed`      — never gives (a hard line, or a compulsion that is simply
        always true of her).
      * `:conditional` — held until `condition` is met by the campaign's canon arc,
        judged by `Polyphony.Authoring.BoundaryGate`. Composing with the arc layer is
        what makes slow burn mechanically real — it holds until the story earns it,
        rather than being a prompt hint the model forgets.

    `on_pressure` is the in-character reaction when pushed *before* it gives (for a
    compulsion, when someone tries to stop her). `after_release` is what she is like
    **once it has turned** — the mock's *and then* / *and now*. It is written when the
    line is created but she is **not told it until it is true of her**, so it only
    reaches her context once `BoundaryGate` releases the gate; telling her in advance
    would let her play the aftermath before earning it.

    ## The ceiling, and which way it fails

    `category` (§A5) is an **optional** link to a content-governance bucket
    (`:sexual | :graphic_violence | :other`). It doesn't conflate the layers — this is
    still pure characterization — it only lets the campaign ceiling *cap* the item
    (`PolyphonyCore.Content.gate_boundary/2`). A pure-characterization item leaves it
    `nil` and the register never touches it.

    The direction matters here, and it is the one place getting it wrong is a real
    bug: **the ceiling always pushes toward refusal.** Capping a refusal means forcing
    it closed — she won't. Capping a *compulsion* by forcing it closed would mean she
    always does it, which is backwards, so the cap turns it into a refusal instead.
    """
    @derive Jason.Encoder
    defstruct [
      :topic,
      :stance,
      :condition,
      :on_pressure,
      :after_release,
      :category,
      direction: :refusal
    ]

    @type stance :: :open | :conditional | :closed
    @type direction :: :refusal | :compulsion
    @type t :: %__MODULE__{
            topic: String.t(),
            stance: stance(),
            direction: direction(),
            condition: String.t() | nil,
            on_pressure: String.t() | nil,
            after_release: String.t() | nil,
            category: PolyphonyCore.Content.category() | nil
          }

    @doc "The two directions, refusals first — the order the sheet lists them in."
    @spec directions() :: [direction()]
    def directions, do: [:refusal, :compulsion]

    @doc "How a direction is written as a section heading (`ux/polyphony-character.html` §05)."
    @spec direction_label(direction()) :: String.t()
    def direction_label(:compulsion), do: "What they can't stop doing"
    def direction_label(_), do: "What they won't do"

    @doc """
    Build a boundary from a string-keyed map (the shape `Autofill.suggest_boundaries`
    returns and the editor form submits): `topic`, `stance`, `direction`, `condition`,
    `on_pressure`, `after_release`, `category`. Unknown/blank stance ⇒ `:closed`;
    unknown direction ⇒ `:refusal`; unknown/blank category ⇒ `nil`; blank strings ⇒
    `nil`. Shared by the sheet editor and Quick Build so the AI-suggested and
    hand-entered paths stay in lockstep.
    """
    @spec from_map(map()) :: t()
    def from_map(m) when is_map(m) do
      %__MODULE__{
        topic: String.trim(to_string(m["topic"] || m[:topic] || "")),
        stance: parse_stance(m["stance"] || m[:stance]),
        direction: parse_direction(m["direction"] || m[:direction]),
        condition: blank_to_nil(m["condition"] || m[:condition]),
        on_pressure: blank_to_nil(m["on_pressure"] || m[:on_pressure]),
        after_release: blank_to_nil(m["after_release"] || m[:after_release]),
        category: parse_category(m["category"] || m[:category])
      }
    end

    defp parse_stance("open"), do: :open
    defp parse_stance("conditional"), do: :conditional
    defp parse_stance(_), do: :closed

    # Anything unrecognised is a refusal: it's the reading that can only make a
    # character *less* likely to act, which is the direction to fail in.
    defp parse_direction(d) when d in ["compulsion", :compulsion], do: :compulsion
    defp parse_direction(_), do: :refusal

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
            # How to refer to them: free text ("she / her", "they / them", "he / him",
            # "ey / em"), never an enum — the set isn't closed, and a fixed list would
            # be a design decision about people rather than about data.
            #
            # This is a *generation* field before it's a display one. Every character
            # prompt renders this sheet; with nothing here the model infers pronouns
            # from a name, which is a guess, and a wrong guess lands inside the fiction
            # — the story misgenders someone, which reads as the story being wrong
            # about them rather than as a setting being unset. `ux/README.md` puts it
            # under copy rules: *pronouns are a field*, because half a sheet's own copy
            # is written about the character and has to be parameterised on it.
            pronouns: nil,
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
            # **Context residency**, and deliberately a second axis from `status`
            # (§2.5). Status says whether the sheet is written; tier says how much
            # the story carries them. They came apart the moment the design settled
            # that nobody plays without a full sheet — if everyone who plays is
            # `:full`, status stops distinguishing the bellman from the lead.
            #
            #   :main       — always resident
            #   :recurring  — resident; a side character who should remember and be
            #                 remembered
            #   :incidental — loaded only for scenes they appear in (the walk-on)
            #
            # Promotion and demotion are both real operations: a walk-on who turns
            # out to matter goes up, and one who has served their purpose comes down
            # rather than being deleted.
            tier: :main,
            # The outward blurb — the only part strangers see before they take a
            # character or a world. Written *from* everything else, secrets included,
            # under instruction to give none of them away, so it is the one generated
            # field whose input deliberately exceeds its permitted output (§2.12).
            cover: nil,
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
  @type tier :: :main | :recurring | :incidental
  @type t :: %__MODULE__{}

  @doc "Cast tiers, most resident first — the order a cast list groups by."
  @spec tiers() :: [tier()]
  def tiers, do: [:main, :recurring, :incidental]

  @doc """
  Does this tier stay in context between scenes?

  `:incidental` is loaded only for the scenes they appear in, which is the whole
  point of the axis: an autogenerated cast can grow without bound, and something
  has to decide who is still in the room when they aren't in the room.
  """
  @spec resident?(t() | tier()) :: boolean()
  def resident?(%__MODULE__{tier: tier}), do: resident?(tier)
  def resident?(tier), do: tier in [:main, :recurring]

  @doc "How a tier is written in the interface (`ux/polyphony-campaign.html`)."
  @spec tier_label(tier()) :: String.t()
  def tier_label(:main), do: "Main cast"
  def tier_label(:recurring), do: "Recurring"
  def tier_label(:incidental), do: "Walk-ons"
  def tier_label(_), do: "Main cast"

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
