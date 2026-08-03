defmodule Polyphony.Events do
  @moduledoc """
  The event catalog (§7).

  Events are **immutable facts** in the log — the single source of truth.
  Corrections are new events (foundational rule 6). A **re-roll** never mutates:
  it appends `PacketSuperseded` markers that drop the beat's tail from every
  projection, then commits fresh packets in their place (§7, §12). A deliberate
  *fork* is a separate mechanism (its own branch/stream) and shares no code with
  re-rolls.

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
    @moduledoc """
    Interior monologue. Visible to `character_id` only. `edited: true` marks a
    user-authored correction (§A4) — the move was hand-edited rather than
    generated, so a client can flag it.
    """
    @derive Jason.Encoder
    defstruct [:character_id, :scene_id, :beat, :packet_id, :seq, :content, :edited]
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
      :audibility,
      :edited
    ]

    # JSON serialization stringifies the `audibility` atom; re-atomize on decode so
    # `Visibility`'s `%SpeechUttered{audibility: :private}` clause matches on events
    # read back from the store. Without this a whisper read from the log would fall
    # through to normal-speech visibility and leak to non-addressees.
    defimpl Commanded.Serialization.JsonDecoder do
      def decode(%SpeechUttered{audibility: a} = e) when is_binary(a),
        do: %{e | audibility: String.to_existing_atom(a)}

      def decode(e), do: e
    end
  end

  defmodule ActionTaken do
    @moduledoc "A physical action. Visible to scene members at `beat`. `edited` per §A4."
    @derive Jason.Encoder
    defstruct [:character_id, :scene_id, :beat, :packet_id, :seq, :content, :edited]
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

  defmodule PacketSuperseded do
    @moduledoc """
    A previously-committed packet is no longer canonical (§7 re-roll, §12). The
    user re-rolled a turn in the latest beat, so this packet — and every packet
    later in the same beat's cast order — is dropped and regenerated in place.

    This is an **append**, not a mutation (rule 6): the superseded packet's events
    stay in the log for history, but every projection filters them out, keyed off
    `packet_id`. `attempt` records which re-roll produced the *replacement* (the
    superseded packet's own attempt is one less). Pacing/structure — user & system
    only, never a character: a re-roll is out-of-world.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :beat, :character_id, :packet_id, :attempt, :reason]
  end

  defmodule WorldEventOccurred do
    @moduledoc """
    A non-character occurrence authored by the Director, scene-scoped. Also how
    rejected proposals surface in-fiction ("she reaches for the door; it's
    locked"). Visible to scene members at `beat`.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :beat, :content]

    @type t :: %__MODULE__{
            scene_id: String.t() | nil,
            beat: integer() | nil,
            content: String.t() | nil
          }
  end

  defmodule SceneOpened do
    @moduledoc "Scene lifecycle. Visibility of the event itself is default-deny."
    @derive Jason.Encoder
    defstruct [:scene_id, :campaign_id, :location_id, :premise, :opened_beat]

    @type t :: %__MODULE__{
            scene_id: String.t() | nil,
            campaign_id: term(),
            location_id: String.t() | nil,
            premise: String.t() | nil,
            opened_beat: integer() | nil
          }
  end

  defmodule SceneClosed do
    @moduledoc "Scene lifecycle."
    @derive Jason.Encoder
    defstruct [:scene_id, :closed_beat]
  end

  defmodule ControlModeSet do
    @moduledoc """
    Who drives a character (§A1, FS V1.7): `control` is `"autonomous"` (the
    Director generates), `"user_controlled"` (the beat yields for a user packet),
    or `"assisted"` (generated as a draft awaiting confirmation — the draft state
    itself is §A2). Per-character, latest-wins; user & system only. Stored as a
    string so it round-trips through the JSON event store unambiguously.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :character_id, :control]
  end

  defmodule TurnOrderDeclared do
    @moduledoc """
    The explicit, user-settable turn order for a beat (§A1): `order` is the ordered
    list of `character_id`s that act, and it is authoritative — the user can
    reorder or **remove** a character by re-declaring. Latest-wins per beat. The
    Director declares a default at beat open; a user override supersedes it. User &
    system only.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :beat, :order]
  end

  defmodule SceneForked do
    @moduledoc """
    A deliberate branch (§7): this scene is a fork of `parent_scene_id`, taken at
    `fork_beat`. It is the first event on the forked scene's own stream, ahead of
    a rewritten copy of the parent's canonical prefix — so a fork is a fully
    independent scene stream, not a live pointer into the parent (copy-on-fork).

    Distinct from a re-roll, which supersedes in place on the *same* stream and
    emits no `SceneForked`. Pacing/structure — user & system only, default-deny to
    characters like the rest of scene lifecycle.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :parent_scene_id, :fork_beat, :label, :campaign_id]
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

  defmodule IntroductionProposed do
    @moduledoc """
    The Director proposes bringing a character on-stage (§B7/B8) — a `name` and the
    `reason` — at `beat`. This is an **authoring/queue signal, not scene canon**: it
    does not make the character a member. It is **omniscient-only** (default-deny for
    characters): in-scene characters must not know about someone who hasn't formally
    entered, or the irony guarantee leaks. The author resolves it from the play view
    (admit / generate / edit / dismiss); admitting emits `CharacterEntered`.
    """
    @derive Jason.Encoder
    defstruct [:scene_id, :beat, :name, :reason]
  end

  defmodule IntroductionDismissed do
    @moduledoc "The author declined a proposed introduction. Omniscient-only; clears the queue item."
    @derive Jason.Encoder
    defstruct [:scene_id, :name]
  end

  defmodule BeatOpened do
    @moduledoc """
    Pacing/structure. User & system only — never a character. `beat_ref` is the
    beat aggregate's stream id; `beat` is the integer scene beat, and `scene_id`
    ties the framing back to a scene so the client can show "a beat is starting".
    """
    @derive Jason.Encoder
    defstruct [:beat_ref, :scene_id, :beat, :cast]
  end

  defmodule BeatClosed do
    @moduledoc """
    The synchronization join point (§12). Carries who committed and who failed
    so the Director can route around a silent character next beat. User & system
    only.
    """
    @derive Jason.Encoder
    defstruct [:beat_ref, :scene_id, :beat, :completed, :failed, :passed]
  end

  defmodule PacketRecorded do
    @moduledoc """
    A character's packet reached the beat as committed. Internal beat-tracking
    for the §12 synchronization unit; user & system only (default deny).
    """
    @derive Jason.Encoder
    defstruct [:beat_ref, :character_id]
  end

  defmodule PacketFailed do
    @moduledoc """
    A character's generation failed within the beat. Carries `scene_id` + `beat`
    so it can surface to the user as `generation.failed` ("Mira didn't respond").
    User & system only (default deny) — never any character.
    """
    @derive Jason.Encoder
    defstruct [:beat_ref, :scene_id, :beat, :character_id, :reason]
  end

  defmodule PacketPassed do
    @moduledoc """
    A **user-controlled** cast member's yield resolved as a skip — the user chose
    not to act this beat (§A1). A terminal beat state alongside committed/failed, so
    a beat awaiting user input can still close once every slot is resolved. User &
    system only.
    """
    @derive Jason.Encoder
    defstruct [:beat_ref, :character_id]
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
