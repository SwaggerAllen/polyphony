defmodule PolyphonyCore.Director.Proposal do
  @moduledoc """
  A character's proposal to change the world, extracted from a committed packet
  (§6.4 `Move.proposal`, §10 arbitration).

  Three kinds, mirroring the constrained-decoding philosophy (§10): the valid
  option set is injected into the character's context so `:exit`/`:interact`
  targets are *enums* — a character structurally cannot propose an imaginary
  exit. `:novel` is the freeform escape hatch and is **always** arbitrated by the
  Director's judgment call.
  """
  @derive Jason.Encoder
  defstruct [:actor_id, :type, :target, :detail]

  @type kind :: :exit | :interact | :novel
  @type t :: %__MODULE__{
          actor_id: term(),
          type: kind(),
          target: String.t() | nil,
          detail: String.t() | nil
        }
end
