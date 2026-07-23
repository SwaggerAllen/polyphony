defmodule Polyphony.Authoring.ArcEntry do
  @moduledoc """
  An interpreted, campaign-scoped arc fact (§6.2).

  Arc is the layer that isn't a mechanical fold over the log — "her brother's
  betrayal hardened her" needs interpretation — so entries carry provenance and a
  review gate (`status`). Everything enters `:proposed`; a human/Director veto
  promotes it to `:canon`. Only `:canon` entries reach the effective sheet.

    * `:discovery` — additive, never contradicts the sheet; resolution is union.
    * `:revision`  — supersession of something authored; resolution is override.
  """
  @derive Jason.Encoder
  defstruct [
    :kind,
    :sheet_field,
    :statement,
    :beat,
    :source_scene_id,
    status: :proposed,
    promotable: true
  ]

  @type t :: %__MODULE__{
          kind: :discovery | :revision,
          sheet_field: String.t() | nil,
          statement: String.t(),
          beat: integer() | nil,
          source_scene_id: term() | nil,
          status: :proposed | :canon | :retracted,
          promotable: boolean()
        }
end
