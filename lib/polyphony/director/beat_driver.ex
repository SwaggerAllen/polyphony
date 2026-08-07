defmodule Polyphony.Director.BeatDriver do
  @moduledoc """
  The beat walk (§A1/§A2) — the Oban-driven beat loop. It consults
  `Director.BeatWalk` for the *decision* (next actionable slot) and *acts* on it in
  the durable/distributed way:

    * **autonomous** → enqueue a `GeneratePacket` (which generates, commits, and
      calls `advance/3` again — serial ordering falls out of the chain);
    * **assisted** → enqueue a `GeneratePacket` in draft mode (generate → pending
      draft → pause);
    * **user-controlled** → broadcast `awaiting.user` and pause;
    * **settled** → close the beat and, per `BeatPolicy`, enqueue the next
      `RunBeat`.

  The user resumes a paused beat via `submit_user_turn/5`, `pass_turn/4`,
  `accept_draft/2`, or `discard_draft/2` — each commits/passes the slot and walks
  on. Because progress is re-derived from the log, a pause needs no stored
  cursor. (A beat resumed by the user closes yielding to the user unless the caller
  passes an explicit `:control` — the sane default when a human is in the loop.)

  In tests the whole loop runs synchronously under
  `Oban.Testing.with_testing_mode(:inline, …)`, offline against the Mock provider.
  """

  require Logger

  alias Polyphony.Scene.Cast
  alias Polyphony.Context.Rebuild
  alias Polyphony.{App, Drafts, Broadcast}
  alias Polyphony.Commands.CommitPacket
  alias Polyphony.Director.{Auto, BeatWalk, BeatOps}
  alias PolyphonyCore.Director.BeatPolicy
  alias PolyphonyCore.Director.Commands.{CloseBeat, RecordPacket, RecordPass}
  alias Polyphony.Jobs.{GeneratePacket, RunBeat}

  @pubsub Polyphony.PubSub

  @doc """
  Act on the next slot of the beat. `opts` carry the loop context forward:
  `:provider`, `:depth`, `:max_depth`, `:control` (partial on resume → defaults).
  """
  @spec advance(term(), integer(), keyword()) :: :ok
  def advance(scene_id, beat, opts \\ []) do
    # An auto run plays *everybody*, control modes included. A user-controlled slot
    # waits for a person, and an assisted one parks a draft for a person to accept —
    # either would stall an unattended run at the first such character and leave it
    # sitting there until somebody noticed. Nothing is changed on the character: the
    # modes are exactly as the author set them, and the next hand-played beat honours
    # them again (§A1/§A2).
    auto? = opts[:auto] == true

    case BeatWalk.next(scene_id, beat) do
      :settled ->
        close(scene_id, beat, opts)

      {:autonomous, character_id} ->
        enqueue_generate(scene_id, beat, character_id, false, opts)

      {:assisted, character_id} ->
        enqueue_generate(scene_id, beat, character_id, not auto?, opts)

      {:user_controlled, character_id} ->
        if auto?,
          do: enqueue_generate(scene_id, beat, character_id, false, opts),
          else: await_user(scene_id, beat, character_id)
    end

    :ok
  end

  # ── Resume entry points (user/frontend triggered) ─────────────────────────────

  @doc "Commit the user's packet for a user-controlled slot, then walk on (§A1)."
  def submit_user_turn(scene_id, beat, character_id, packet, opts \\ []) do
    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene_id,
        character_id: character_id,
        beat: beat,
        packet_id: BeatOps.packet_id(scene_id, beat, character_id),
        # A human wrote this one, so its whisper targets are names too (§5.2).
        packet: Cast.resolve_addressees(Rebuild.cast_for(scene_id), packet)
      })

    :ok =
      App.dispatch(%RecordPacket{
        beat_ref: BeatOps.beat_ref(scene_id, beat),
        character_id: character_id
      })

    advance(scene_id, beat, opts)
  end

  @doc "Skip a user-controlled slot, then walk on (§A1)."
  def pass_turn(scene_id, beat, character_id, opts \\ []) do
    :ok =
      App.dispatch(%RecordPass{
        beat_ref: BeatOps.beat_ref(scene_id, beat),
        character_id: character_id
      })

    advance(scene_id, beat, opts)
  end

  @doc "Accept an assisted draft (commit it), then walk on (§A2)."
  def accept_draft(draft_id, opts \\ []) do
    case Drafts.accept(draft_id, repo: repo(opts)) do
      {:ok, %{scene_id: scene_id, beat: beat, character_id: character_id}} ->
        :ok =
          App.dispatch(%RecordPacket{
            beat_ref: BeatOps.beat_ref(scene_id, beat),
            character_id: character_id
          })

        advance(scene_id, beat, opts)

      error ->
        error
    end
  end

  @doc "Discard an assisted draft (the slot passes), then walk on (§A2)."
  def discard_draft(draft_id, opts \\ []) do
    case Drafts.get(draft_id, repo: repo(opts)) do
      nil ->
        {:error, :not_found}

      row ->
        Drafts.discard(draft_id, repo: repo(opts))

        :ok =
          App.dispatch(%RecordPass{
            beat_ref: BeatOps.beat_ref(row.scene_id, row.beat),
            character_id: row.character_id
          })

        advance(row.scene_id, row.beat, opts)
    end
  end

  # ── Acting on a slot ──────────────────────────────────────────────────────────

  defp enqueue_generate(scene_id, beat, character_id, draft?, opts) do
    # Tell the play view which character is generating now (blocks input, shows who).
    Broadcast.announce_progress(scene_id, :generating, subject: character_id, beat: beat)

    %{
      "scene_id" => scene_id,
      "beat" => beat,
      "character_id" => character_id,
      "packet_id" => BeatOps.packet_id(scene_id, beat, character_id),
      "beat_ref" => BeatOps.beat_ref(scene_id, beat),
      "chain" => true,
      "draft" => draft?,
      "auto" => opts[:auto] == true,
      "provider" => provider_arg(opts[:provider]),
      "depth" => opts[:depth] || 0,
      "max_depth" => opts[:max_depth] || BeatPolicy.default_max_depth(),
      "control" => control_str(opts[:control]),
      # Carry the campaign-owner attribution so the cast turn bills the owner (§B5).
      "user_id" => opts[:user_id],
      "campaign_id" => opts[:campaign_id],
      # Campaign LLM tuning (§9): the character's output-token budget, the workhorse
      # model it generates on, and the heavy model to fall back to on a refusal. nil ⇒
      # the provider's global default.
      "character_max_tokens" => opts[:character_max_tokens],
      "model" => opts[:character_model],
      "heavy_model" => opts[:heavy_model],
      # DeepInfra scheduling tier (§9): carried so the whole cast shares the campaign's.
      "service_tier" => opts[:service_tier]
    }
    |> GeneratePacket.new()
    |> Oban.insert!()
  end

  defp await_user(scene_id, beat, character_id) do
    Broadcast.announce_progress(scene_id, :awaiting_user, subject: character_id, beat: beat)

    Phoenix.PubSub.broadcast(@pubsub, Broadcast.topic(scene_id, :omniscient), {
      :polyphony_event,
      %{
        type: "awaiting.user",
        viewer: "omniscient",
        scene_id: scene_id,
        beat: beat,
        character_id: character_id
      }
    })
  end

  defp close(scene_id, beat, opts) do
    :ok = App.dispatch(%CloseBeat{beat_ref: BeatOps.beat_ref(scene_id, beat)})
    depth = opts[:depth] || 0
    max_depth = opts[:max_depth] || BeatPolicy.default_max_depth()

    next =
      BeatPolicy.next(%{
        depth: depth,
        control: opts[:control] || :yield_to_user,
        membership_changed: false,
        max_depth: max_depth
      })

    if next == :continue do
      # Another beat runs immediately — the next RunBeat announces :director itself.
      # `auto` rides along so a self-chained beat is still an auto beat and hits the
      # run's gate; without it the chain would keep going past a pause.
      RunBeat.enqueue(%{
        "scene_id" => scene_id,
        "beat" => beat + 1,
        "depth" => depth + 1,
        "max_depth" => max_depth,
        "provider" => provider_arg(opts[:provider]),
        "auto" => opts[:auto] == true,
        "control_hint" => if(opts[:auto], do: "auto", else: control_str(opts[:control]))
      })
    else
      # The beat settled and nothing follows — the loop is idle, the reliable "done"
      # signal the transcript stream never carried. For an auto run that *is* the end:
      # the depth cap is the beat cap, and nothing else will enqueue for this scene.
      if opts[:auto], do: Auto.finish(scene_id, :cap)
      Broadcast.announce_progress(scene_id, :idle, beat: beat)
    end
  end

  # ── Coercion ──────────────────────────────────────────────────────────────────

  defp repo(opts), do: opts[:repo] || Polyphony.Repo

  # provider round-trips through JSON job args as a module-name string.
  defp provider_arg(nil), do: nil
  defp provider_arg(mod) when is_atom(mod), do: to_string(mod)
  defp provider_arg(str) when is_binary(str), do: str

  defp control_str(:continue), do: "continue"
  defp control_str("continue"), do: "continue"
  defp control_str(_), do: "yield_to_user"
end
