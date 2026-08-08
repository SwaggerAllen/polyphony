defmodule Polyphony.Authoring.Group do
  @moduledoc """
  A group: a character-shaped template that people are written from, and that
  secrets can point at.

  The design's own definition (`ux/polyphony-campaign.html` §06b): *a group is
  written like a character and used as a starting point for others — a crew, a
  household, an order. It saves writing the same person five times, and gives
  secrets somewhere to point.* So it sits beside Cast rather than off in its own
  corner, and it carries the parts of a character sheet that make sense for a
  collective — what they're like, what they know — and none of the parts that only
  make sense for a person (a name they answer to, their own relationships, their
  own arc).

  ## Two jobs, and the rule that keeps them apart

  **It seeds.** Anyone written from a group starts with its fields and knows
  whatever it knows (`Polyphony.Groups.seed_sheet/2`). Seeding is a **copy**: the
  character gets their own facts from that moment, and editing the template later
  does not reach back into people already written from it. That's what makes group
  arc a fan-out rather than a silent propagation (`completed-roadmap.md` §3.0b) —
  nothing propagates without review, which is the rule everywhere else.

  **It belongs.** Membership is a set of characters, and it is what an audience
  means when it names a group: *groups are named, not expanded — the membership
  moves* (`ux/polyphony-audience-picker.html`). A secret pointed at the Tidewatch
  is pointed at whoever is in the Tidewatch when the question is asked, not at the
  list of names that were in it when the secret was written.

  The two are deliberately independent. Joining a group later does **not** backfill
  what you know — the design is explicit that the reveal is fiction, not a
  migration, the same principle as world-arc catch-up. Seeding happens once, at
  creation; membership is a live set. A character can be in a group they were never
  seeded from, and seeded from a group they later leave.
  """

  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Fact

  defstruct name: nil,
            # Character-shaped, so the same editor and the same generation path can
            # write it. These are the fields that seed a person; a group has no
            # `voice`, no relationships and no boundaries of its own, because those
            # belong to whoever is written from it.
            premise: nil,
            appearance: nil,
            temperament: nil,
            backstory: nil,
            facts: [],
            # Who is in it, by stable library id. Ordered, so the UI is stable.
            member_ids: [],
            # **The scope key** (STR-68): the campaign this group was written in, by
            # library entry id. Groups do not cross campaigns, the same rule characters
            # follow — attaching a world copies the bible and brings no groups with it.
            #
            # Nil is a real state, not a missing value: a group written before this
            # field, or one whose campaign was deleted, belongs to no campaign. Those
            # stay visible on the library shelf so they can be deleted, and appear on no
            # campaign hub. See `Polyphony.Groups.orphans/2`.
            campaign_id: nil,
            # The world this group is written against — an **authoring** link, not the
            # scope key, and it kept its job when `campaign_id` took that one over. It
            # is what `seed_sheet/2` passes to a character written from this group, so
            # they inherit the setting rather than having to be told it again.
            #
            # Scoping on it was the bug: `campaign.md` decides that attaching a world
            # *copies* it, so a campaign's bible is private to that campaign and world
            # scope nearly coincides with campaign scope. The case that breaks is a
            # group written from the **library**, which points at the template bible no
            # campaign holds — matching no hub, or with a nil id, matching every hub.
            world_bible_id: nil,
            # A group takes a hue like a character does, so it reads as one thing
            # across the cast list and the audience picker.
            hue: nil

  @type t :: %__MODULE__{}

  @doc "The kind under which groups are stored in the library."
  @spec kind() :: String.t()
  def kind, do: "group"

  @doc """
  A stored group, with any field it predates filled in from the defaults.

  A payload is an Erlang term written when it was written, so one saved before
  `campaign_id` existed decodes to a struct **without that key** — and reading it as
  `group.campaign_id` raises `KeyError` rather than answering nil. That is a real
  hazard here because the field was added to a live table: every group in the database
  predates it until the backfill runs, and a screen that reads it directly would have
  crashed on all of them.

  The incantation was already in use at one call site (`GroupEditorLive.mount/3`, added
  when `world_bible_id` was the new field). This is the same thing, named once, so the
  next field to arrive doesn't need it re-derived at whichever site notices first.
  """
  @spec load(t() | map()) :: t()
  def load(%__MODULE__{} = group), do: struct(__MODULE__, Map.from_struct(group))

  @doc """
  The group's secrets — the facts membership is what grants you.

  The count the design shows on a group row ("6 members · seeds new people · 2
  secrets") and the reason a group is somewhere for a secret to point.
  """
  @spec secrets(t()) :: [Fact.t()]
  def secrets(%__MODULE__{facts: facts}),
    do: Enum.filter(facts || [], & &1.concealed)

  @doc """
  Seed a character sheet from this group.

  Fills only what the sheet hasn't got: a group is a *starting point*, so anything
  already written on the character wins. Facts are appended rather than replaced,
  because the character may already have their own and the group's are additional
  — including its secrets, since knowing them is what belonging means.

  A **copy**, deliberately. Editing the group afterwards reaches nobody already
  written from it; that's §3.0b's fan-out, which goes through review.
  """
  @spec seed(t(), CharacterSheet.t()) :: CharacterSheet.t()
  def seed(%__MODULE__{} = group, %CharacterSheet{} = sheet) do
    %CharacterSheet{
      sheet
      | premise: keep(sheet.premise, group.premise),
        appearance: keep(sheet.appearance, group.appearance),
        temperament: keep(sheet.temperament, group.temperament),
        backstory: keep(sheet.backstory, group.backstory),
        world_bible_id: sheet.world_bible_id || group.world_bible_id,
        facts: (sheet.facts || []) ++ new_facts(sheet, group)
    }
  end

  # Anything the author already wrote wins — seeding never overwrites.
  defp keep(existing, _seed) when is_binary(existing) and existing != "", do: existing
  defp keep(_existing, seed), do: seed

  # Re-seeding must not duplicate: matched on the statement, which is what a reader
  # would call "the same fact".
  defp new_facts(sheet, group) do
    held = MapSet.new(sheet.facts || [], & &1.statement)
    Enum.reject(group.facts || [], &MapSet.member?(held, &1.statement))
  end
end
