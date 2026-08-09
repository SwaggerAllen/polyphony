defmodule Polyphony.Authoring.ArcEntry do
  @moduledoc """
  An interpreted, campaign-scoped arc fact (§6.2).

  Arc is the layer that isn't a mechanical fold over the log — "her brother's
  betrayal hardened her" needs interpretation — so entries carry provenance and a
  review gate (`status`). Everything enters `:proposed`; a human/Director veto
  promotes it to `:canon`. Only `:canon` entries reach the effective sheet.

    * `:discovery` — additive, never contradicts the sheet; resolution is union.
    * `:revision`  — supersession of something authored; resolution is override.
    * `:release`   — a line gave. A conditional boundary whose condition play met, named
      by `released_topic`. `Polyphony.Authoring.BoundaryGate` already resolved it
      *scene-locally* from canon arc; this is what makes it permanent, which is the
      distinction `ux/polyphony-arc.html` §02 draws — *the gate already resolved this in
      play; review is where it becomes permanent rather than scene-local.*

  ## Because

  `reason` is what in the scene caused the proposal, and it is not decoration: the
  design's argument is that it *is* what makes accepting quick, because you can check
  the reasoning without going back and rereading the scene. A proposal that can't say
  why is a proposal you have to earn twice.

  ## Authored entries (STR-62)

  The author can propose too, and their proposals are the same object — same card,
  same accept-or-refuse, same place in the history. `author` is *who says so* where
  `reason` is *what in the story made this true*; an authored entry always carries an
  author and may carry a Because. `nil` author means the engine.

  Authored entries add three axes an extracted one never carries:

    * `operation` — `:add | :change | :remove | :satisfied`. Satisfaction is its own
      operation because a line that gives is a change of *state*, not of value: the
      consequence was written in advance, and satisfying only asks whether the
      condition was met.
    * `timing` — `:always | :scene | :now`. *Always true* corrects the person you
      originally wrote and folds **before** everything play has done; *in a scene*
      takes its place in the timeline there; *just now* is true from now, tied to no
      scene.
    * `replaces` — the value or list item a change supersedes (the card's Was line,
      and how a list operation names *which one*).

  A release proposal also carries `condition_met`: `false` means the Director is
  proposing past the line's written condition, and the card shows that condition
  struck through and marked unmet — the author needs to see their own rule being gone
  past rather than silently reinterpreted. `nil` reads as met, which is what every
  pre-existing release row means.
  """
  @derive Jason.Encoder
  defstruct [
    :kind,
    :sheet_field,
    :statement,
    :reason,
    :released_topic,
    :beat,
    :source_scene_id,
    :author,
    :operation,
    :timing,
    :replaces,
    :direction,
    :line_condition,
    :after_release,
    :condition_met,
    :core,
    :target,
    :target_id,
    :audience,
    concealed: false,
    status: :proposed,
    promotable: true
  ]

  @type kind :: :discovery | :revision | :release
  @type operation :: :add | :change | :remove | :satisfied
  @type timing :: :always | :scene | :now

  @type t :: %__MODULE__{
          kind: kind(),
          sheet_field: String.t() | nil,
          statement: String.t(),
          reason: String.t() | nil,
          released_topic: String.t() | nil,
          beat: integer() | nil,
          source_scene_id: term() | nil,
          author: String.t() | nil,
          operation: operation() | nil,
          timing: timing() | nil,
          replaces: String.t() | nil,
          direction: :refusal | :compulsion | nil,
          line_condition: String.t() | nil,
          after_release: String.t() | nil,
          condition_met: boolean() | nil,
          core: boolean() | nil,
          target: String.t() | nil,
          target_id: String.t() | nil,
          audience: Polyphony.Authoring.Audience.t() | nil,
          concealed: boolean(),
          status: :proposed | :canon | :retracted,
          promotable: boolean()
        }

  @doc "How a kind reads as a proposal's heading (`ux/polyphony-arc.html` §02)."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{operation: :satisfied}), do: "A line, satisfied"
  def label(%__MODULE__{operation: :remove, sheet_field: "relationships"}), do: "A regard, ended"
  def label(%__MODULE__{operation: :remove}), do: "No longer true"
  def label(%__MODULE__{sheet_field: "relationships"}), do: "A relationship"
  def label(%__MODULE__{kind: :release, condition_met: false}), do: "A line broke"
  def label(%__MODULE__{kind: :release}), do: "A line gave"

  def label(%__MODULE__{kind: :revision, sheet_field: f}) when is_binary(f) and f != "",
    do: "#{String.capitalize(String.replace(f, "_", " "))}, revised"

  def label(%__MODULE__{kind: :revision}), do: "Something changed"
  def label(%__MODULE__{sheet_field: "initial_knowledge"}), do: "Something she now knows"
  def label(%__MODULE__{}), do: "A new fact"
end
