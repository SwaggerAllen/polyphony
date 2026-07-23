defmodule Polyphony.Events do
  @moduledoc """
  The event catalog (§7).

  Events are **immutable facts** in the log — the single source of truth.
  Corrections are new events; re-rolls fork the branch (foundational rule 6).

  Field conventions shared across the character-emitted events:

    * `beat`      — the grouping label: which user action prompted this cluster.
                    NOT an ordering key on its own (generation is serial, §10);
                    total order is the event store's global sequence.
    * `packet_id` — deterministic id `(branch_id, beat, character_id)` shared by
                    every event decomposed from one `TurnPacket`, so downstream
                    filtering stays event-type based, never field based (§6.4).
    * `seq`       — position of the originating `Move` within its packet.

  Visibility is decided structurally in `Polyphony.Visibility`, keyed off these
  fields — never by a prompt instruction and never self-reported (rule 4).
  """

  defmodule ThoughtOccurred do
    @moduledoc "Interior monologue. Visible to `character_id` only."
    @derive Jason.Encoder
    defstruct [:character_id, :scene_id, :beat, :packet_id, :seq, :content]
  end

  defmodule PrivateStateReported do
    @moduledoc """
    The private half of a `SelfState` snapshot — what the character feels and
    intends. Visible to `character_id` only. The observable half rides on
    `DemeanorReported`. Splitting them is what gives dramatic irony at the state
    layer: furious (`mood_felt`) but composed (`demeanor`), §6.3.
    """
    @derive Jason.Encoder
    defstruct [:character_id, :scene_id, :beat, :packet_id, :mood_felt, :intention]
  end

  defmodule SpeechUttered do
    @moduledoc """
    A spoken move. When `audibility: :private` only the speaker and everyone in
    `addressed_to` hear it (whispers, nearly free irony machinery). When
    `:normal`, everyone who was a scene member at `beat` hears it.
    """
    @derive Jason.Encoder
    defstruct [
      :speaker_id,
      :scene_id,
      :beat,
      :packet_id,
      :seq,
      :content,
      :addressed_to,
      :audibility
    ]
  end

  defmodule ActionTaken do
    @moduledoc "A physical action. Visible to scene members at `beat`."
    @derive Jason.Encoder
    defstruct [:character_id, :scene_id, :beat, :packet_id, :seq, :content]
  end

  defmodule DemeanorReported do
    @moduledoc """
    The observable half of a `SelfState` snapshot — how the character reads to
    others. Visible to scene members at `beat`. Snapshot, not delta: if a field
    stops being mentioned it has decayed (§6.4).
    """
    @derive Jason.Encoder
    defstruct [
      :character_id,
      :scene_id,
      :beat,
      :packet_id,
      :demeanor,
      :posture,
      :position,
      :attending_to
    ]
  end

  defmodule WorldEventOccurred do
    @moduledoc """
    A non-character occurrence authored by the Director, scene-scoped. Also how
    rejected proposals surface in-fiction ("she reaches for the door; it's
    locked"). Visible to scene members at `beat`.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :beat, :content]
  end

  defmodule SceneOpened do
    @moduledoc "Scene lifecycle. Visibility of the event itself is default-deny."
    @derive Jason.Encoder
    defstruct [:scene_id, :campaign_id, :location_id, :premise, :opened_beat]
  end

  defmodule SceneClosed do
    @moduledoc "Scene lifecycle."
    @derive Jason.Encoder
    defstruct [:scene_id, :closed_beat]
  end

  defmodule CharacterEntered do
    @moduledoc """
    A membership change. Visible to scene members at `beat` (they see who walked
    in). Also drives the `scene_memberships` interval read model.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :character_id, :beat]
  end

  defmodule CharacterExited do
    @moduledoc "A membership change. Visible to scene members at `beat`."
    @derive Jason.Encoder
    defstruct [:scene_id, :character_id, :beat]
  end

  defmodule BeatOpened do
    @moduledoc "Pacing/structure. User & system only — never a character."
    @derive Jason.Encoder
    defstruct [:beat, :cast]
  end

  defmodule BeatClosed do
    @moduledoc """
    The synchronization join point (§12). Carries who committed and who failed
    so the Director can route around a silent character next beat. User & system
    only.
    """
    @derive Jason.Encoder
    defstruct [:beat, :completed, :failed]
  end

  defmodule GenerationFailed do
    @moduledoc """
    A generation job reached a terminal failure. **Visible to the user only,
    never to any character** (§7, §12) — in-world they simply didn't speak.
    """
    @derive Jason.Encoder
    defstruct [:beat, :character_id, :reason]
  end

  defmodule ArcEntryProposed do
    @moduledoc """
    An interpreted arc fact surfaced at scene close (§6.2). Enters as
    `:proposed`; a human/Director veto promotes it to `:canon`. Not visible in
    any character's play projection (it is authoring metadata).
    """
    @derive Jason.Encoder
    defstruct [
      :arc_entry_id,
      :subject_id,
      :subject_type,
      :kind,
      :sheet_field,
      :statement,
      :beat,
      :source_scene_id
    ]
  end

  defmodule ArcEntryAccepted do
    @moduledoc "An arc entry promoted `:proposed -> :canon`."
    @derive Jason.Encoder
    defstruct [:arc_entry_id, :subject_id]
  end
end
