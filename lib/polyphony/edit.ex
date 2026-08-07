defmodule Polyphony.Edit do
  @moduledoc """
  Editing committed turns (§A4): a correction that **supersedes** the original,
  never a mutation (rule 6). The original stays in history; the corrected packet
  becomes canonical.

  Every edit carries the user's downstream-validity choice, because serial
  generation means a changed line may have changed what *later* turns conditioned
  on — and only the user knows whether it did:

    * `:valid` — the change invalidates nothing downstream (a typo, a reword).
      Pure supersession, in place on the same stream; the rest of the timeline is
      untouched. Works on any beat.
    * `:invalid` — the change alters what happened, so everything conditioned on
      it is stale. **Forks** at the edit point (reusing §7 branching): the
      original timeline is preserved intact, and a new branch carries the edit
      with the now-stale tail discarded, ready to re-play or re-roll.

  Mechanically an edit is a user-authored re-commit — the same supersede + commit
  primitive a re-roll uses, but the replacement is the caller's corrected packet
  rather than a generated one, committed with `edited: true`. Corrections are
  ordinary committed events, so they obey visibility like anything else: editing a
  private thought stays private.
  """

  alias Polyphony.Scene.Cast
  alias Polyphony.{App, Fork}
  alias PolyphonyCore.Packets
  alias Polyphony.Commands.{SupersedePacket, CommitPacket}
  alias Polyphony.Director.BeatOps

  @doc """
  Edit the committed packet for `character_id` in `beat`, replacing it with
  `corrected` (a `TurnPacket`). `validity` is `:valid` (correct in place) or
  `:invalid` (fork and apply on the branch).

  Returns `{:ok, %{scene_id:, packet_id:, forked:, ...}}` — `scene_id` is where
  the corrected packet landed (the branch, when forked). `{:error,
  :packet_not_found}` if the character has no packet in the beat.

  Opts (for `:invalid`) pass to the fork: `:label`, `:new_scene_id`.
  """
  @spec edit(term(), integer(), term(), struct(), :valid | :invalid, keyword()) ::
          {:ok, map()} | {:error, :packet_not_found}
  def edit(scene_id, beat, character_id, corrected, validity, opts \\ [])

  def edit(scene_id, beat, character_id, corrected, :valid, _opts) do
    with {:ok, [{_char, target_id} | _]} <- tail(scene_id, beat, character_id) do
      # The user asserts downstream is fine: supersede only this packet, leave the
      # in-beat tail and every later beat exactly as they are.
      supersede(scene_id, beat, character_id, target_id)
      new_id = commit_corrected(scene_id, beat, character_id, corrected)
      {:ok, %{scene_id: scene_id, packet_id: new_id, forked: false}}
    end
  end

  def edit(scene_id, beat, character_id, corrected, :invalid, opts) do
    with {:ok, _} <- tail(scene_id, beat, character_id) do
      # Preserve the original timeline on its own branch; apply the edit on a fork
      # taken through the edit beat, discarding what conditioned on the edited turn
      # (its in-beat tail; later beats never crossed the fork).
      {:ok, branch} = Fork.fork(scene_id, beat, Keyword.take(opts, [:label, :new_scene_id]))
      {:ok, branch_tail} = tail(branch, beat, character_id)

      Enum.each(branch_tail, fn {char, pid} -> supersede(branch, beat, char, pid) end)
      new_id = commit_corrected(branch, beat, character_id, corrected)

      {:ok, %{scene_id: branch, packet_id: new_id, forked: true, parent_scene_id: scene_id}}
    end
  end

  # ── Primitives ────────────────────────────────────────────────────────────

  defp tail(scene_id, beat, character_id) do
    scene_id
    |> BeatOps.stored_events()
    |> Packets.canonical()
    |> Packets.beat_tail(beat, character_id)
  end

  defp supersede(scene_id, beat, character_id, packet_id) do
    :ok =
      App.dispatch(%SupersedePacket{
        scene_id: scene_id,
        beat: beat,
        character_id: character_id,
        packet_id: packet_id,
        reason: "edit"
      })
  end

  defp commit_corrected(scene_id, beat, character_id, corrected) do
    attempt =
      scene_id |> BeatOps.stored_events() |> BeatOps.next_attempt(scene_id, beat, character_id)

    new_id = BeatOps.reroll_packet_id(scene_id, beat, character_id, attempt)

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene_id,
        character_id: character_id,
        beat: beat,
        packet_id: new_id,
        # The correction came back from the model in display names; the log takes ids.
        packet: Cast.resolve_addressees(scene_id, corrected),
        edited: true
      })

    new_id
  end
end
