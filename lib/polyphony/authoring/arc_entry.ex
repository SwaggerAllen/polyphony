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
    status: :proposed,
    promotable: true
  ]

  @type kind :: :discovery | :revision | :release

  @type t :: %__MODULE__{
          kind: kind(),
          sheet_field: String.t() | nil,
          statement: String.t(),
          reason: String.t() | nil,
          released_topic: String.t() | nil,
          beat: integer() | nil,
          source_scene_id: term() | nil,
          status: :proposed | :canon | :retracted,
          promotable: boolean()
        }

  @doc "How a kind reads as a proposal's heading (`ux/polyphony-arc.html` §02)."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{kind: :release}), do: "A line gave"

  def label(%__MODULE__{kind: :revision, sheet_field: f}) when is_binary(f) and f != "",
    do: "#{String.capitalize(String.replace(f, "_", " "))}, revised"

  def label(%__MODULE__{kind: :revision}), do: "Something changed"
  def label(%__MODULE__{sheet_field: "initial_knowledge"}), do: "Something she now knows"
  def label(%__MODULE__{}), do: "A new fact"
end
