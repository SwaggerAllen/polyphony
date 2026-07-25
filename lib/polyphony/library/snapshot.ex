defmodule Polyphony.Library.Snapshot do
  @moduledoc """
  The **publish snapshot** (§B1): a self-contained, frozen copy of a campaign.

  Publishing embeds pinned dependency **versions** — the world bible and each
  character sheet as they were, plus a **frozen arc snapshot at the published
  beat** — rather than referencing the owner's live library. The rationale is
  independence: an external consumer must not depend on the owner's working set,
  which may be edited, deleted, or privatized. A normal branch is the opposite: a
  *live* pointer into that working set.

  Two axes stay separate (§B1): **published/private** (visibility, on the library
  entry) and **live/frozen** (referenced vs embedded, this struct). Publishing
  implies freeze, but they remain distinct properties.

  ## Arc is canon-only by default

  `:proposed` arc entries are excluded from the snapshot unless `include_proposed:
  true` — publishing an interpreted, half-reviewed arc would leak guesses as canon.
  Publishing resolves the proposed tail upstream (accept-all / review / publish
  without); by the time it reaches here the choice is a single `include_proposed`
  flag.

  ## Published view is omniscient

  A published campaign exposes the **omniscient** log — private thoughts, private
  state, and both arcs, including concealed facts that became canon. That is
  inherent to publishing an omniscient story; `omniscient_log/1` guarantees the
  published projection is exactly `Polyphony.Visibility`'s omniscient one, never an
  accidental firehose of raw events.
  """

  alias Polyphony.Visibility

  @derive Jason.Encoder
  defstruct campaign_id: nil,
            published_beat: nil,
            bible: nil,
            characters: [],
            arc: [],
            include_proposed: false,
            derived_from_id: nil,
            derived_from_version: nil

  @type pinned_character :: %{source_id: term(), source_version: integer(), sheet: map()}
  @type t :: %__MODULE__{
          campaign_id: term(),
          published_beat: integer() | nil,
          bible: map() | nil,
          characters: [pinned_character()],
          arc: [map()],
          include_proposed: boolean(),
          derived_from_id: integer() | nil,
          derived_from_version: integer() | nil
        }

  @doc """
  Build a frozen snapshot from a campaign's live dependencies.

  `attrs`: `:campaign_id`, `:published_beat`, `:bible`, `:characters` (a list of
  `%{source_id:, source_version:, sheet:}`), `:arc` (arc-entry maps).
  Opts: `:include_proposed` (default `false`).
  """
  @spec build(map() | keyword(), keyword()) :: t()
  def build(attrs, opts \\ []) do
    attrs = Map.new(attrs)
    include_proposed = Keyword.get(opts, :include_proposed, false)
    published_beat = Map.get(attrs, :published_beat)

    %__MODULE__{
      campaign_id: Map.get(attrs, :campaign_id),
      published_beat: published_beat,
      bible: Map.get(attrs, :bible),
      characters: Map.get(attrs, :characters, []),
      arc: resolve_arc(Map.get(attrs, :arc, []), published_beat, include_proposed),
      include_proposed: include_proposed
    }
  end

  @doc """
  The frozen arc: canon-only by default, and only entries **at or before** the
  published beat (a later beat isn't part of this snapshot). Entries with no beat
  (authored starting canon) are always in. `include_proposed?` opts the proposed
  tail in.
  """
  @spec resolve_arc([map()], integer() | nil, boolean()) :: [map()]
  def resolve_arc(arc, published_beat, include_proposed?) do
    Enum.filter(arc, fn entry ->
      canon_ok?(entry, include_proposed?) and beat_ok?(entry, published_beat)
    end)
  end

  @doc """
  The published log for a scene's events: the **omniscient** projection, never the
  raw stream. This is what makes the published view the omniscient story (§B1).
  """
  @spec omniscient_log([struct()]) :: [struct()]
  def omniscient_log(events), do: Visibility.project(events, :omniscient)

  # ── Filters ───────────────────────────────────────────────────────────────

  defp canon_ok?(_entry, true), do: true
  defp canon_ok?(entry, false), do: to_string(Map.get(entry, :status)) == "canon"

  defp beat_ok?(_entry, nil), do: true

  defp beat_ok?(entry, published_beat) do
    case Map.get(entry, :beat) do
      nil -> true
      beat -> beat <= published_beat
    end
  end
end
