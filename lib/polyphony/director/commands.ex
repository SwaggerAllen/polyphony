defmodule Polyphony.Director.Commands do
  @moduledoc "Commands for the beat aggregate (§12)."

  defmodule OpenBeat do
    defstruct [:beat, :cast]
  end

  defmodule RecordPacket do
    defstruct [:beat, :character_id]
  end

  defmodule RecordFailure do
    defstruct [:beat, :character_id, :reason]
  end

  defmodule CloseBeat do
    defstruct [:beat]
  end
end
