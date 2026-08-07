defmodule PolyphonyCore.Events.TypeProvider do
  @moduledoc """
  The name an event is stored under, decided here rather than by where its module lives.

  Commanded's default (`Commanded.Serialization.ModuleNameTypeProvider`) writes
  `Atom.to_string(struct.__struct__)` into the event store's `event_type` column and reads
  it back with `String.to_existing_atom/1`. That makes **the module path part of the stored
  data**: moving `Polyphony.Events.SpeechUttered` to `PolyphonyCore.Events.SpeechUttered`
  renames a column value in every row already written, and the log is the single source of
  truth — so a rename that compiles cleanly and passes a suite that only round-trips
  freshly-written events still makes every historical event undecodable.

  That is not a hypothetical: the move into `PolyphonyCore` did exactly this, and nothing
  caught it, because a test that writes an event and reads it back agrees with itself no
  matter what the name is.

  So the names here are **stable strings that no refactor can move**: `snake_case` plus a
  `.v1` suffix, holding a place for the day an event's shape changes incompatibly and a
  `.v2` has to coexist with rows already written as `.v1`. A module may now be renamed,
  re-namespaced, or moved between boundaries without touching stored data.

  ## Reading what is already there

  `to_struct/1` accepts three spellings of every event:

    * the stable name — `"speech_uttered.v1"`, what is written from now on;
    * `"Elixir.PolyphonyCore.Events.SpeechUttered"` — written between the move and this
      module;
    * `"Elixir.Polyphony.Events.SpeechUttered"` — written before the move.

  which makes this a **migration as well as a fix**: no rewrite of the event store is
  needed, and a database holding all three spellings reads correctly. The legacy clauses
  are load-bearing history and must not be deleted, however dead they look — the rows they
  decode are immutable facts, and the only evidence they still exist is in a production
  database nobody is going to grep.

  ## Anything that is not an event

  A struct with no entry falls back to its module name, which keeps aggregate snapshots and
  process-manager state working the way Commanded expects (this app uses neither, but a
  type provider that raised on them would turn "we enabled snapshotting" into a puzzling
  crash). `TypeProviderTest` pins the catalog to `PolyphonyCore.Events` in both directions,
  so a new event added without a name is a failing test rather than a struct silently
  falling through to the fragile default.
  """

  @behaviour Commanded.EventStore.TypeProvider

  alias PolyphonyCore.Events

  @catalog [
    {Events.ThoughtOccurred, "thought_occurred.v1"},
    {Events.PrivateStateReported, "private_state_reported.v1"},
    {Events.SpeechUttered, "speech_uttered.v1"},
    {Events.ActionTaken, "action_taken.v1"},
    {Events.DemeanorReported, "demeanor_reported.v1"},
    {Events.PacketSuperseded, "packet_superseded.v1"},
    {Events.WorldEventOccurred, "world_event_occurred.v1"},
    {Events.SceneOpened, "scene_opened.v1"},
    {Events.SceneClosed, "scene_closed.v1"},
    {Events.ControlModeSet, "control_mode_set.v1"},
    {Events.TurnOrderDeclared, "turn_order_declared.v1"},
    {Events.SceneForked, "scene_forked.v1"},
    {Events.CharacterEntered, "character_entered.v1"},
    {Events.CharacterExited, "character_exited.v1"},
    {Events.IntroductionProposed, "introduction_proposed.v1"},
    {Events.IntroductionDismissed, "introduction_dismissed.v1"},
    {Events.BeatOpened, "beat_opened.v1"},
    {Events.BeatClosed, "beat_closed.v1"},
    {Events.PacketRecorded, "packet_recorded.v1"},
    {Events.PacketFailed, "packet_failed.v1"},
    {Events.PacketPassed, "packet_passed.v1"},
    {Events.GenerationFailed, "generation_failed.v1"},
    {Events.ArcEntryProposed, "arc_entry_proposed.v1"},
    {Events.ArcEntryAccepted, "arc_entry_accepted.v1"}
  ]

  @doc """
  The catalog as `{module, stored_name}` pairs. Public so the test can pin it against the
  event vocabulary rather than restating it.
  """
  @spec catalog() :: [{module(), String.t()}]
  def catalog, do: @catalog

  @legacy_namespaces ["Elixir.PolyphonyCore.Events.", "Elixir.Polyphony.Events."]

  @doc """
  The namespaces this event vocabulary has lived in, newest first. Every one of them is
  still accepted on read.
  """
  @spec legacy_namespaces() :: [String.t()]
  def legacy_namespaces, do: @legacy_namespaces

  @impl true
  def to_string(struct)

  for {module, name} <- @catalog do
    def to_string(%unquote(module){}), do: unquote(name)
  end

  # Not an event: a snapshot's source state, or a process manager's. Commanded's own
  # behaviour for these is the module name, and nothing here improves on it.
  def to_string(struct) when is_map(struct), do: Atom.to_string(struct.__struct__)

  @impl true
  def to_struct(type)

  for {module, name} <- @catalog do
    def to_struct(unquote(name)), do: %unquote(module){}

    short = module |> Module.split() |> List.last()

    for namespace <- @legacy_namespaces do
      def to_struct(unquote(namespace <> short)), do: %unquote(module){}
    end
  end

  def to_struct(type), do: type |> String.to_existing_atom() |> struct()
end
