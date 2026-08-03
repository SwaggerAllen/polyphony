defmodule Polyphony.SceneControl do
  @moduledoc """
  Manual scene control + Continue (§B7) — the author's direct levers over a scene,
  alongside the Director's autonomous casting.

  * **Add / remove a character** emits `CharacterEntered` / `CharacterExited`
    directly, bypassing Director casting. Changes take effect **at the given beat
    boundary**, never mid-packet — the half-open `[entered, exited)` membership
    interval (§8) and the §10 truncation rule already guarantee this; the caller
    passes the boundary beat. Adding a **stub** character (§B8) is refused until it
    is promoted — casting an unwritten character would generate from nothing.
  * **Continue** is the empty user turn: advance the scene with no user packet and
    let the Director cast and proceed. Mechanically it is just a beat run with no
    committed input — an explicit no-op-input path over the existing loop.
  """

  alias Polyphony.App
  alias Polyphony.Commands.{EnterCharacter, ExitCharacter}
  alias Polyphony.Jobs.RunBeat

  @doc """
  Add `character_id` to `scene_id`, effective at `beat`. Refuses a `:stub` (pass
  `status: :stub` for an unpromoted character) with `{:error, :stub_needs_promotion}`
  so the UI can promote first (§B8).
  """
  # `{:ok, _}` is in the range because `Commanded.Application.dispatch/2` returns the
  # aggregate state (or the emitted events) under some dispatch options, not only `:ok`.
  @spec add_character(term(), term(), integer(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def add_character(scene_id, character_id, beat, opts \\ []) do
    case Keyword.get(opts, :status, :full) do
      :full ->
        App.dispatch(%EnterCharacter{scene_id: scene_id, character_id: character_id, beat: beat})

      :stub ->
        {:error, :stub_needs_promotion}

      # A :proposed (promoted but unaccepted) character is not usable yet either.
      _other ->
        {:error, :needs_promotion}
    end
  end

  @doc "Remove `character_id` from `scene_id`, effective at `beat` (the boundary)."
  @spec remove_character(term(), term(), integer(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def remove_character(scene_id, character_id, beat, _opts \\ []) do
    App.dispatch(%ExitCharacter{scene_id: scene_id, character_id: character_id, beat: beat})
  end

  @doc """
  Continue the scene with an **empty user turn**: kick a beat run for `beat` with no
  committed user packet, letting the Director cast and proceed. `:enqueue` overrides
  the runner (tests inject a capture); it defaults to `RunBeat.enqueue/1`.
  """
  @spec continue(term(), integer(), keyword()) :: term()
  def continue(scene_id, beat, opts \\ []) do
    enqueue = Keyword.get(opts, :enqueue, &RunBeat.enqueue/1)

    args =
      %{"scene_id" => scene_id, "beat" => beat, "continue" => true}
      |> Map.merge(Map.new(Keyword.get(opts, :args, %{})))

    enqueue.(args)
  end
end
