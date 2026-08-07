defmodule Polyphony.Core.TurnOrder do
  @moduledoc """
  Reading the declarative §A1 turn-order and control-mode facts off a scene's log.

  Two independent things, both latest-wins and both read straight from the stream
  (the aggregate doesn't fold them — they're read-side facts, like membership):

    * **turn order** per beat (`TurnOrderDeclared`) — the ordered `character_id`s
      that act; a user override supersedes the Director's default, and omitting a
      character removes them from the beat.
    * **control mode** per character (`ControlModeSet`) — `autonomous` (generate),
      `user_controlled` (yield for a user packet), or `assisted` (draft, §A2).

  The beat loop walks the order and yields on `user_controlled`; re-roll reads the
  mode so it never regenerates a user's turn.
  """

  alias Polyphony.Events.{TurnOrderDeclared, ControlModeSet}

  @default_control "autonomous"

  @doc "The declared turn order for `beat` (latest declaration wins), or nil if none."
  def for_beat(events, beat) do
    events
    |> Enum.filter(&match?(%TurnOrderDeclared{beat: ^beat}, &1))
    |> case do
      [] -> nil
      declarations -> List.last(declarations).order
    end
  end

  @doc "A character's control mode (latest `ControlModeSet`), defaulting to autonomous."
  def control_mode(events, character_id) do
    cid = to_string(character_id)

    events
    |> Enum.filter(fn
      %ControlModeSet{character_id: c} -> to_string(c) == cid
      _ -> false
    end)
    |> case do
      [] -> @default_control
      sets -> List.last(sets).control
    end
  end

  @doc "Is this character user-driven (the beat must yield) rather than generated?"
  def user_controlled?(events, character_id),
    do: control_mode(events, character_id) == "user_controlled"
end
