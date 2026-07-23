defmodule Polyphony.Visibility do
  @moduledoc """
  The core guarantee (§8): dramatic irony as a **projection**, not a prompt.

  A character's context is a filtered replay of the event stream. If an event
  was never visible to a character, it was never in their projection, and they
  *structurally cannot* reference it. Protect this above all else.

  Two design commitments are enforced here:

    * **Default deny (rule 3).** Any event type not explicitly granted is
      invisible to characters. The failure mode of a forgotten clause is a
      character knowing *too little*, never too much.

    * **One predicate for every viewer (§13).** The omniscient user is not an
      unfiltered firehose — it is `viewer: :omniscient` routed through this same
      function. A second human is just another viewer value, which is what keeps
      multiplayer a config change rather than a rewrite.

  Membership is evaluated **at the event's beat**, not "now" — a character sees
  only what they could witness *when it happened*. The membership oracle is a
  `(scene_id, character_id, beat) -> boolean` closure so the pure
  `Polyphony.MembershipSet` and the Postgres read model are interchangeable.
  """

  alias Polyphony.Events.{
    ThoughtOccurred,
    PrivateStateReported,
    SpeechUttered,
    ActionTaken,
    DemeanorReported,
    WorldEventOccurred,
    CharacterEntered,
    CharacterExited
  }

  @type viewer :: :omniscient | {:character, term()}
  @type member_at? :: (term(), term(), integer() -> boolean())

  @doc """
  Is `event` visible to `viewer`, given a membership oracle?

  The omniscient viewer sees everything (still routed here, never bypassing).
  Characters see only what the predicate grants; everything else is denied.
  """
  @spec visible_to?(struct(), viewer(), member_at?()) :: boolean()
  def visible_to?(_event, :omniscient, _member_at?), do: true

  def visible_to?(event, {:character, char_id}, member_at?)
      when is_function(member_at?, 3) do
    case event do
      # Interior events: self only.
      %ThoughtOccurred{} = e ->
        e.character_id == char_id

      %PrivateStateReported{} = e ->
        e.character_id == char_id

      # Whispers: speaker + explicit recipients only, regardless of who else is
      # in the scene. Pure irony machinery.
      %SpeechUttered{audibility: :private} = e ->
        char_id in [e.speaker_id | e.addressed_to || []]

      # Observable, scene-scoped events: witnessed iff a member at the beat.
      %SpeechUttered{} = e ->
        member_at?.(e.scene_id, char_id, e.beat)

      %ActionTaken{} = e ->
        member_at?.(e.scene_id, char_id, e.beat)

      %DemeanorReported{} = e ->
        member_at?.(e.scene_id, char_id, e.beat)

      %WorldEventOccurred{} = e ->
        member_at?.(e.scene_id, char_id, e.beat)

      %CharacterEntered{} = e ->
        member_at?.(e.scene_id, char_id, e.beat)

      %CharacterExited{} = e ->
        member_at?.(e.scene_id, char_id, e.beat)

      # DEFAULT DENY (rule 3): Thought/PrivateState of others, scene lifecycle,
      # beat structure, generation failures, arc entries — none reach a
      # character unless a clause above grants it.
      _ ->
        false
    end
  end

  @doc """
  Filter an ordered event stream down to `viewer`'s projection.

  This is the exact operation used to build a character's context and to drive
  the per-viewer client stream — the same filtering, so the transport can never
  leak more than the context (§13). Order is preserved.
  """
  @spec project(Enumerable.t(), viewer(), member_at?()) :: [struct()]
  def project(events, viewer, member_at?) do
    Enum.filter(events, &visible_to?(&1, viewer, member_at?))
  end

  @doc """
  Convenience: project a stream for `viewer`, deriving the membership oracle
  from the same stream via `Polyphony.MembershipSet`.

  Purely a projection over the log — no external state — which is what makes it
  safe to hand-write events in tests and assert the guarantee directly (§15
  slice 1).
  """
  @spec project(Enumerable.t(), viewer()) :: [struct()]
  def project(events, viewer) do
    events = Enum.to_list(events)

    member_at? =
      events |> Polyphony.MembershipSet.from_events() |> Polyphony.MembershipSet.member_at_fun()

    project(events, viewer, member_at?)
  end
end
