defmodule Polyphony.Authoring.WorldBible do
  @moduledoc """
  The authored, portable world layer (§6.7): setting, tone, and **rules/physics**.

  Rules go into *every* character's stable prefix — cheap, and they keep
  generation from contradicting the setting (§6.7). Because the bible is authored
  and rarely changes, it sits at the very top of the cached prefix (refresh:
  never, §9).

  ## Entries, and the one control in three places

  `rules` and `starting_canon` are lists of `Entry` — a statement plus `concealed`.
  The design's rule (`ux/polyphony-world.html` §04) is that **anything can be marked
  secret: one control, three places — a rule, a canon entry, a character's fact** —
  and that a secret stays out of the cover, out of browse, and out of any
  perspective that shouldn't have it.

  For a world entry, that last clause is the whole point and it is **structural, not
  a prompt instruction**: `public/1` is what the character-facing renderer reads, so
  a concealed world fact never reaches a character's context at all. The Director,
  being omniscient, reads `statements/1` and sees everything. Getting this backwards
  would be the world-level version of the leak `PolyphonyCore.Visibility` exists to
  prevent, and it would leak into *prompts*, where nobody can see it happen.

  **Who else knows a secret is not modelled yet** (`completed-roadmap.md` §3.3, the
  audience picker). Until it is, `concealed: true` means what its default says —
  nobody starts out knowing. That is the safe direction: a character knows too
  little, never too much.

  A bare string is accepted everywhere an entry is (`Entry.from/1`), so payloads
  written before this field existed, and generation that returns plain lines, both
  read as public entries without a migration.
  """

  defmodule Entry do
    @moduledoc """
    One authored world statement — a rule, or something already true.

    `concealed` is the same flag a character's `Fact` carries and means the same
    thing: this is narrower than everyone. It is *not* a scope — a `:local` world-arc
    fact is about **where** it reached, this is about **who** knows.

    `audience` is who that narrower set is (`Polyphony.Authoring.Audience`), and it is
    the same component on the same question here as on a character's fact. Nobody, by
    default.
    """
    @derive Jason.Encoder
    defstruct [:statement, :audience, concealed: false]

    @type t :: %__MODULE__{
            statement: String.t(),
            concealed: boolean(),
            audience: Polyphony.Authoring.Audience.t() | nil
          }

    @doc """
    Coerce a stored value into an entry.

    Accepts an `Entry`, a plain string (a payload written before entries existed, or
    a generated line), or a string-keyed map from the editor form. A bare string is
    **public** — the failure direction that shows an author their own world rather
    than silently hiding it from them.
    """
    @spec from(t() | String.t() | map()) :: t()
    def from(%__MODULE__{} = entry), do: entry
    def from(statement) when is_binary(statement), do: %__MODULE__{statement: statement}

    def from(%{} = m) do
      %__MODULE__{
        statement: to_string(m["statement"] || m[:statement] || ""),
        concealed: truthy?(m["concealed"] || m[:concealed]),
        audience: Polyphony.Authoring.Audience.from(m["audience"] || m[:audience])
      }
    end

    defp truthy?(true), do: true
    defp truthy?("true"), do: true
    defp truthy?(_), do: false
  end

  @derive Jason.Encoder
  defstruct name: nil,
            # The outward blurb — the only part strangers see before they take this
            # world. Written from everything below it, secrets included, under
            # instruction to give none of them away (§2.12).
            cover: nil,
            setting: nil,
            tone: nil,
            rules: [],
            starting_canon: []

  @type t :: %__MODULE__{
          name: String.t() | nil,
          cover: String.t() | nil,
          setting: String.t() | nil,
          tone: String.t() | nil,
          rules: [Entry.t()],
          starting_canon: [Entry.t()]
        }

  @doc "A list of entries, whatever shape it was stored or submitted in."
  @spec entries([Entry.t() | String.t() | map()]) :: [Entry.t()]
  def entries(list), do: list |> List.wrap() |> Enum.map(&Entry.from/1)

  @doc """
  Every statement in a list — the **omniscient** read.

  What the Director sees, what the cover is written from, and what an author edits.
  """
  @spec statements([Entry.t() | String.t() | map()]) :: [String.t()]
  def statements(list), do: for(e <- entries(list), do: e.statement)

  @doc """
  Only the statements nobody is being kept from — the **character-facing** read.

  Every path that builds a character's context goes through this or `known_to/3`
  rather than through `statements/1`. A new caller that reaches for the raw list is
  the bug.
  """
  @spec public([Entry.t() | String.t() | map()]) :: [String.t()]
  def public(list), do: for(e <- entries(list), not e.concealed, do: e.statement)

  @doc """
  The bible a **stranger** may take — every concealed entry removed.

  Taking a world out of somebody's published story copies the setting, not their
  secrets: what an author kept back was never shared, and it doesn't travel. The
  design says this on the screen rather than implying it away — *some of this world
  isn't shown; those don't come with it*.

  Concealed entries are dropped outright rather than blanked, so nothing downstream
  can accidentally read a placeholder as a real one, and the `cover` survives because
  it was written under instruction to give none of them away (§2.12).
  """
  @spec stripped(t()) :: t()
  def stripped(%__MODULE__{} = bible) do
    %__MODULE__{
      bible
      | rules: keep_public(bible.rules),
        starting_canon: keep_public(bible.starting_canon)
    }
  end

  defp keep_public(list), do: for(e <- entries(list), not e.concealed, do: e)

  @doc "The concealed statements — what a cover must be checked against (§2.12)."
  @spec secrets(t()) :: [String.t()]
  def secrets(%__MODULE__{} = bible),
    do:
      for(
        e <- entries(bible.rules) ++ entries(bible.starting_canon),
        e.concealed,
        do: e.statement
      )
end
