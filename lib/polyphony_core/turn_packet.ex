defmodule PolyphonyCore.TurnPacket do
  @moduledoc """
  A character's turn (§6.4) — the unit a character emits per beat, before it is
  decomposed into individual events by the Scene aggregate.

  A packet is `moves` (ordered, capped ~4-5) plus one end-of-packet `SelfState`
  snapshot. The handler splits it into separate events sharing `beat` and
  `packet_id`, so visibility filtering stays event-type based, not field based.
  """

  defmodule Move do
    @moduledoc """
    One ordered move. `addressed_to`/`audibility` are meaningful only for
    `:speech`. Membership-changing proposals (deferred to the Director slice)
    must be terminal within a packet — enforced at decomposition time.
    """
    @derive Jason.Encoder
    defstruct [
      :seq,
      :type,
      :content,
      addressed_to: [],
      audibility: :normal
    ]

    @type t :: %__MODULE__{
            seq: integer(),
            type: :thought | :speech | :action,
            content: String.t(),
            addressed_to: [term()],
            audibility: :normal | :private
          }
  end

  defmodule SelfState do
    @moduledoc """
    End-of-packet snapshot (§6.4). Split at decomposition into the private half
    (`mood_felt`, `intention` → `PrivateStateReported`) and the observable half
    (`demeanor`, `posture`, `position`, `attending_to` → `DemeanorReported`).
    Snapshot, not delta: unmentioned fields decay.
    """
    @derive Jason.Encoder
    defstruct [:mood_felt, :demeanor, :intention, :attending_to, :position, :posture]

    @type t :: %__MODULE__{
            mood_felt: String.t() | nil,
            demeanor: String.t() | nil,
            intention: String.t() | nil,
            attending_to: String.t() | nil,
            position: String.t() | nil,
            posture: String.t() | nil
          }
  end

  @derive Jason.Encoder
  defstruct moves: [], self_state: nil

  @type t :: %__MODULE__{moves: [Move.t()], self_state: SelfState.t() | nil}
end
