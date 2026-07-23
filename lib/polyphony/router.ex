defmodule Polyphony.Router do
  @moduledoc "Routes commands to aggregates by their identity field."
  use Commanded.Commands.Router

  alias Polyphony.Scene

  alias Polyphony.Commands.{OpenScene, CloseScene, EnterCharacter, ExitCharacter, CommitPacket}

  identify(Scene, by: :scene_id)

  dispatch([OpenScene, CloseScene, EnterCharacter, ExitCharacter, CommitPacket], to: Scene)
end
