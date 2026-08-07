defmodule Polyphony.Reroll do
  @moduledoc """
  Re-rolls: regenerate a turn (and the rest of its beat) in place (§7, §12).

  A beat's cast is decided **once**, at beat-open, then generated serially — so a
  re-roll of the packet for `C_k` in a beat with cast `[C_1 … C_n]` has a single
  well-defined meaning: `C_k … C_n` were the turns that reacted, directly or
  transitively, to `C_k`. Re-rolling `C_k` invalidates exactly that tail. We

    1. **supersede** the tail up front (`SupersedePacket` — append-only, rule 6),
       so the canonical log for the beat is truncated to its head, then
    2. **regenerate** the tail serially, reusing `Jobs.GeneratePacket` wholesale
       (same generation + `CommitPacket`, same refusal→heavy-model retry). Each
       member re-reads the canonical log, so `C_{k+1}` conditions on the *new*
       `C_k`.

  Nothing forks: no new stream, no branch. A re-roll stays on the scene's own log
  and is bounded to the **latest** beat — touching an earlier beat would
  invalidate every beat that conditioned on it, which is a deliberate *fork*, a
  separate mechanism (`{:error, :not_latest_beat}`).
  """

  alias Polyphony.App
  alias PolyphonyCore.{Packets, TurnOrder}
  alias Polyphony.Commands.SupersedePacket
  alias Polyphony.Director.BeatOps
  alias Polyphony.Jobs.GeneratePacket

  @doc """
  Re-roll the packet for `character_id` in `beat` and regenerate the beat's tail.

  Returns `{:ok, %{beat:, superseded: [packet_id], results: [{character_id,
  outcome}]}}` where each `outcome` is the `GeneratePacket` standalone result
  (`:ok | {:cancel, reason} | {:error, reason}`). Errors: `:not_latest_beat`
  (that's a fork, not a re-roll) or `:packet_not_found`.

  Opts pass through to generation: `:provider`, `:model`.
  """
  @spec reroll(term(), term(), term(), keyword()) ::
          {:ok, map()} | {:error, :not_latest_beat | :packet_not_found}
  def reroll(scene_id, beat, character_id, opts \\ []) do
    raw = BeatOps.stored_events(scene_id)
    canonical = Packets.canonical(raw)

    with :ok <- ensure_latest_beat(canonical, beat),
         {:ok, tail} <- Packets.beat_tail(canonical, beat, character_id) do
      plan = Enum.map(tail, &plan_member(scene_id, beat, &1, raw))

      # Supersede the whole tail first, so each regeneration conditions only on
      # the beat's head plus the replacements committed before it.
      Enum.each(plan, &supersede(scene_id, beat, &1))
      results = Enum.map(plan, &replace(scene_id, beat, &1, raw, opts))

      {:ok, %{beat: beat, superseded: Enum.map(plan, & &1.superseded_id), results: results}}
    end
  end

  # ── Planning ──────────────────────────────────────────────────────────────

  defp plan_member(scene_id, beat, {character_id, superseded_id}, raw) do
    attempt = BeatOps.next_attempt(raw, scene_id, beat, character_id)

    %{
      character_id: character_id,
      superseded_id: superseded_id,
      attempt: attempt,
      new_id: BeatOps.reroll_packet_id(scene_id, beat, character_id, attempt)
    }
  end

  defp ensure_latest_beat(canonical, beat) do
    if Packets.latest_beat(canonical) == beat, do: :ok, else: {:error, :not_latest_beat}
  end

  # ── Supersede + regenerate ────────────────────────────────────────────────

  defp supersede(scene_id, beat, member) do
    :ok =
      App.dispatch(%SupersedePacket{
        scene_id: scene_id,
        beat: beat,
        character_id: member.character_id,
        packet_id: member.superseded_id,
        attempt: member.attempt,
        reason: "reroll"
      })
  end

  # A user-controlled member's turn is theirs to write (§A1): it's superseded
  # (it conditioned on the change) but never LLM-regenerated — the beat re-yields
  # for them. Autonomous members regenerate.
  defp replace(scene_id, beat, member, raw, opts) do
    if TurnOrder.user_controlled?(raw, member.character_id) do
      {member.character_id, :awaiting_user}
    else
      regenerate(scene_id, beat, member, opts)
    end
  end

  # Reuse the one generation+commit unit. No `messages` in args, so it rebuilds
  # them from the *canonical* live log (`BeatOps.messages_for`) — the tail
  # re-conditions on the replacements as they land.
  defp regenerate(scene_id, beat, member, opts) do
    args =
      %{
        "scene_id" => scene_id,
        "character_id" => member.character_id,
        "beat" => beat,
        "packet_id" => member.new_id
      }
      |> maybe_put("provider", opts[:provider] && to_string(opts[:provider]))
      |> maybe_put("model", opts[:model])

    {member.character_id, GeneratePacket.perform(%Oban.Job{args: args})}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
