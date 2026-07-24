defmodule Polyphony.Director.Commands do
  @moduledoc "Commands for the beat aggregate (§12)."

  defmodule OpenBeat do
    @moduledoc "`beat_ref` is the aggregate identity; `beat` is the integer scene beat."
    defstruct [:beat_ref, :scene_id, :beat, :cast]
  end

  defmodule RecordPacket do
    defstruct [:beat_ref, :character_id]
  end

  defmodule RecordFailure do
    defstruct [:beat_ref, :character_id, :reason]
  end

  defmodule CloseBeat do
    defstruct [:beat_ref]
  end
end
