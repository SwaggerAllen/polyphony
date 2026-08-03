defmodule PolyphonyWeb.Play.Strip do
  @moduledoc """
  The status strip's data: a slot per cast member, and one sentence.

  The design puts this above the composer in both registers and gives it a strict
  job (`ux/polyphony-play.html` §02): *tracker plus one sentence*. No beat number —
  the transcript's beat rule owns that — and no navigation. Everything here is
  derived, never stored: the beat aggregate already records who took their turn,
  who passed and who failed, and the declared turn order says who is still to come.

  **Every member of the beat gets a slot, for every viewer.** Presence is currently
  binary and symmetric — `Membership` is a half-open interval and `visible_to?/3`
  judges membership at the beat — so there is no such thing as being in a scene but
  unknown to the people in it. Filtering the strip per viewer would model a
  distinction the domain doesn't have, and it would cost a player the thing the
  strip is *for*: seeing that the beat is moving rather than hung.

  Concealed presence is a real feature and it is specced — `backend-backlog.md`
  §2.1 (per-observer presence) and §2.2 (turn-order visibility). When it lands, the
  treatment here is a **greyed placeholder** rather than an omission, with runs of
  consecutive concealed slots collapsed into one, so the tracker still accounts for
  the time the beat spends on them. It has to land with the **context-generation**
  half at the same time: a concealed character leaking into a prompt is the version
  of this that actually matters, and a half-built version that only filters the UI
  would hide the problem rather than solve it.

  The sentence is the one place the strip speaks. It follows the copy rule that a
  line says what is happening rather than what the rule is — "Wren is writing.
  You're next." rather than "generation in progress" — and it is written from the
  viewer's position, so the same beat reads differently to a player and the GM.
  """

  alias Polyphony.Events.{BeatOpened, PacketFailed, PacketPassed, PacketRecorded}
  alias PolyphonyWeb.Voice

  @typedoc "One slot: who, what state, whether it's the viewer."
  @type slot :: %{
          id: String.t(),
          label: String.t(),
          name: String.t(),
          state: :took | :now | :wait | :pass | :fail,
          colour: String.t() | nil,
          you: boolean()
        }

  @typedoc "The strip: slots in turn order, plus the sentence and its tone."
  @type t :: %{slots: [slot()], sentence: String.t() | nil, tone: String.t() | nil}

  @doc """
  Build the strip for a viewer.

  `opts`:

    * `:beat_events` — the beat aggregate's own stream (`BeatOps.beat_events/2`)
    * `:order` — the declared turn order for the beat, or nil
    * `:members` — who is in the scene, used when no beat has opened yet
    * `:viewer` — `:omniscient` or `{:character, id}`
    * `:generating` — the character id currently being generated, if any
    * `:voices` / `:names` — display maps, both keyed by character id
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    beat_events = Keyword.get(opts, :beat_events, [])
    viewer = Keyword.get(opts, :viewer, :omniscient)
    names = Keyword.get(opts, :names, %{})
    voices = Keyword.get(opts, :voices, %{})
    generating = Keyword.get(opts, :generating)

    state = fold(beat_events)
    cast = cast_for(opts, state)
    slots = Enum.map(cast, &slot(&1, state, generating, viewer, names, voices))

    %{slots: slots, sentence: sentence(slots, viewer, names), tone: tone(slots, viewer)}
  end

  # ── Cast ──────────────────────────────────────────────────────────────────────

  # Turn order is authoritative when declared (a GM reorder is honoured, §A1);
  # otherwise the beat's opening cast; otherwise the room, which is what a scene
  # shows before its first beat opens. The same list for every viewer — see the
  # moduledoc on why this isn't filtered.
  defp cast_for(opts, state) do
    case Enum.uniq(Enum.map(Keyword.get(opts, :order) || state.cast || [], &to_string/1)) do
      [] -> opts |> Keyword.get(:members, []) |> Enum.map(&to_string/1) |> Enum.uniq()
      declared -> declared
    end
  end

  # ── Slots ─────────────────────────────────────────────────────────────────────

  defp slot(id, state, generating, viewer, names, voices) do
    name = Map.get(names, id, id)
    slot_state = state_of(id, state, generating)

    %{
      id: id,
      name: name,
      label: label(name),
      state: slot_state,
      # Only a taken turn is filled with the character's hue — the other states are
      # carried by the kit's own border treatments, and colouring them too would
      # make five states read as one.
      colour: if(slot_state == :took, do: Voice.of(voices, id)),
      you: viewer == {:character, id}
    }
  end

  defp state_of(id, state, generating) do
    cond do
      MapSet.member?(state.completed, id) -> :took
      Map.has_key?(state.failed, id) -> :fail
      MapSet.member?(state.passed, id) -> :pass
      to_string(generating || "") == id -> :now
      true -> :wait
    end
  end

  # Slots flex, so a long cast becomes initials — the kit's rule, at the size it
  # gives (around six). Below that there's room for a short name, and the first word
  # is the one worth showing: "Wren Ashgrove" is WREN, not WREN&nbsp;A. Truncating the
  # whole string instead would make "Mother Corrigan" read MOTH.
  defp label(name) do
    name
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> case do
      nil -> "?"
      word -> word |> String.slice(0, 5) |> String.upcase()
    end
  end

  @doc """
  Shorten every label to an initial.

  The caller decides when: the kit's threshold is "around six", which is a layout
  fact the view knows and this module doesn't.
  """
  @spec to_initials(t()) :: t()
  def to_initials(%{slots: slots} = strip) do
    %{strip | slots: Enum.map(slots, &%{&1 | label: String.slice(&1.label, 0, 1)})}
  end

  # ── The sentence ──────────────────────────────────────────────────────────────

  defp sentence([], _viewer, _names), do: nil

  defp sentence(slots, {:character, _}, names) do
    you = Enum.find(slots, & &1.you)

    cond do
      failed = Enum.find(slots, &(&1.state == :fail)) ->
        "#{failed.name}'s turn didn't come through."

      you && you.state == :now ->
        "Your turn."

      writing = Enum.find(slots, &(&1.state == :now)) ->
        "#{writing.name} is writing." <> waiting_suffix(slots, you)

      you && you.state == :pass ->
        "You passed." <> next_up(slots)

      you && you.state == :took ->
        "You've taken your turn." <> next_up(slots)

      true ->
        sentence(slots, :omniscient, names)
    end
  end

  defp sentence(slots, :omniscient, _names) do
    cond do
      failed = Enum.find(slots, &(&1.state == :fail)) ->
        "#{failed.name}'s turn didn't come through."

      writing = Enum.find(slots, &(&1.state == :now)) ->
        "#{writing.name} is writing."

      Enum.all?(slots, &(&1.state in [:took, :pass])) ->
        "Everyone has taken the beat."

      waiting = Enum.find(slots, &(&1.state == :wait)) ->
        "Waiting on #{waiting.name}."

      true ->
        nil
    end
  end

  # "You're next" vs "two turns until yours" — the design's own phrasing, and the
  # reason the strip is worth having: it answers *when do I act* without counting.
  defp waiting_suffix(_slots, nil), do: ""

  defp waiting_suffix(slots, you) do
    case turns_until(slots, you) do
      nil -> ""
      0 -> " You're next."
      1 -> " One turn until yours."
      n -> " #{n + 1} turns until yours."
    end
  end

  defp turns_until(slots, you) do
    if you.state == :wait do
      slots
      |> Enum.drop_while(&(&1.state != :now))
      |> Enum.drop(1)
      |> Enum.take_while(&(&1.id != you.id))
      |> length()
    end
  end

  defp next_up(slots) do
    case Enum.find(slots, &(&1.state == :now)) do
      nil -> ""
      writing -> " #{writing.name} is taking their turn."
    end
  end

  # Lamp is "now", pencil is a correction — the two semantics the kit reserves. An
  # ordinary line takes neither and renders dim.
  defp tone(slots, viewer) do
    you = Enum.find(slots, & &1.you)

    cond do
      Enum.any?(slots, &(&1.state == :fail)) -> "var(--pencil)"
      viewer != :omniscient and you && you.state == :now -> "var(--lamp)"
      true -> nil
    end
  end

  # ── Beat state ────────────────────────────────────────────────────────────────

  # The same fold the Beat aggregate does, over the beat's own stream. Read rather
  # than reached for: the aggregate's state isn't queryable, and re-deriving it here
  # keeps this a pure function of the log.
  defp fold(events) do
    Enum.reduce(
      events,
      %{cast: [], completed: MapSet.new(), failed: %{}, passed: MapSet.new()},
      fn
        %BeatOpened{cast: cast}, acc -> %{acc | cast: Enum.map(cast || [], &to_string/1)}
        %PacketRecorded{character_id: id}, acc -> update(acc, :completed, id)
        %PacketPassed{character_id: id}, acc -> update(acc, :passed, id)
        %PacketFailed{character_id: id, reason: r}, acc -> fail(acc, id, r)
        _e, acc -> acc
      end
    )
  end

  defp update(acc, key, id),
    do: Map.update!(acc, key, &MapSet.put(&1, to_string(id)))

  defp fail(acc, id, reason),
    do: Map.update!(acc, :failed, &Map.put(&1, to_string(id), reason))
end
