defmodule Polyphony.Commands do
  @moduledoc """
  Commands — requests to change state. A command is validated by an aggregate,
  which either emits events or rejects it. Generation never happens here or in
  the aggregate (rule 1); jobs *produce* these commands (rule 2).
  """

  defmodule OpenScene do
    defstruct [:scene_id, :campaign_id, :location_id, :premise, :opened_beat]
  end

  defmodule CloseScene do
    defstruct [:scene_id, :closed_beat]
  end

  defmodule EnterCharacter do
    defstruct [:scene_id, :character_id, :beat]
  end

  defmodule ExitCharacter do
    defstruct [:scene_id, :character_id, :beat]
  end

  defmodule CommitPacket do
    @moduledoc """
    Commit a character's `TurnPacket` into the scene. The aggregate decomposes
    it into typed events sharing `beat` and `packet_id`. `packet_id` is derived
    deterministically upstream `(branch, beat, character_id)` for idempotency
    (§12), so a retried job commits once.
    """
    defstruct [:scene_id, :character_id, :beat, :packet_id, :packet, :edited]
  end

  defmodule SupersedePacket do
    @moduledoc """
    Mark a committed packet no longer canonical (§7 re-roll). Emitted by the
    re-roll orchestrator for the re-rolled packet and every packet later in the
    beat's cast order, before their replacements are committed. Append-only
    correction (rule 6): the aggregate records the supersession, it never mutates
    or drops the original events. `attempt` is the re-roll index of the
    replacement packet.
    """
    defstruct [:scene_id, :beat, :character_id, :packet_id, :attempt, :reason]
  end

  defmodule ForkScene do
    @moduledoc """
    Create a deliberate branch (§7) as a new, independent scene stream.

    `prefix` is a rewritten copy of the parent's **canonical** events through
    `fork_beat` (scene id and packet ids re-pointed onto the new stream), gathered
    by `Polyphony.Fork` — the aggregate never reads another stream (rule 1); the
    orchestrator does that and hands the events in. The aggregate emits
    `SceneForked` followed by that prefix, so the fork replays as an ordinary open
    scene that every existing projection handles unchanged.
    """
    defstruct [:scene_id, :parent_scene_id, :fork_beat, :label, :campaign_id, :prefix]
  end

  defmodule RecordWorldEvent do
    @moduledoc """
    Author a Director world event into a scene (§10). Non-character occurrences
    and in-fiction rejections ("the door is locked") land on the log this way,
    visible to scene members at the beat.
    """
    defstruct [:scene_id, :beat, :content]
  end
end
