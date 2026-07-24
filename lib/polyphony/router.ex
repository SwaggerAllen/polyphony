defmodule Polyphony.Router do
  @moduledoc "Routes commands to aggregates by their identity field."
  use Commanded.Commands.Router

  alias Polyphony.{Scene, Director}

  alias Polyphony.Commands.{
    OpenScene,
    CloseScene,
    EnterCharacter,
    ExitCharacter,
    CommitPacket,
    RecordWorldEvent
  }

  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordFailure, CloseBeat}

  identify(Scene, by: :scene_id)
  identify(Director.Beat, by: :beat_ref)

  dispatch(
    [OpenScene, CloseScene, EnterCharacter, ExitCharacter, CommitPacket, RecordWorldEvent],
    to: Scene
  )

  dispatch([OpenBeat, RecordPacket, RecordFailure, CloseBeat], to: Director.Beat)
end
