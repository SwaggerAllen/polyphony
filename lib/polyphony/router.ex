defmodule Polyphony.Router do
  @moduledoc "Routes commands to aggregates by their identity field."
  use Commanded.Commands.Router

  alias PolyphonyCore.Scene
  # The Beat aggregate is in the core (`deps: []`); the rest of `Director` is not.
  alias PolyphonyCore.Director

  alias PolyphonyCore.Commands.{
    OpenScene,
    CloseScene,
    EnterCharacter,
    ExitCharacter,
    CommitPacket,
    SupersedePacket,
    ForkScene,
    SetControlMode,
    DeclareTurnOrder,
    RecordWorldEvent,
    ProposeIntroduction,
    DismissIntroduction
  }

  alias PolyphonyCore.Director.Commands.{
    OpenBeat,
    RecordPacket,
    RecordFailure,
    RecordPass,
    CloseBeat
  }

  identify(Scene, by: :scene_id)
  identify(Director.Beat, by: :beat_ref)

  dispatch(
    [
      OpenScene,
      CloseScene,
      EnterCharacter,
      ExitCharacter,
      CommitPacket,
      SupersedePacket,
      ForkScene,
      SetControlMode,
      DeclareTurnOrder,
      RecordWorldEvent,
      ProposeIntroduction,
      DismissIntroduction
    ],
    to: Scene
  )

  dispatch([OpenBeat, RecordPacket, RecordFailure, RecordPass, CloseBeat], to: Director.Beat)
end
