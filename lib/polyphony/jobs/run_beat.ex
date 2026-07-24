defmodule Polyphony.Jobs.RunBeat do
  @moduledoc """
  The beat coordinator job — the Oban-driven half of the beat loop (§10).

  Per firing it makes the one Director judgment call (an LLM call, legitimately
  inside a job), applies the plan, and hands off to serial cast generation:

    1. `Director.decide/1` — Stage-1 arbitration + Stage-2 judgment.
    2. Author world events; apply membership-changing actions.
    3. If membership changed → **truncate**: enqueue the next `RunBeat` (re-decide
       against the new membership) unless the depth cap is hit.
    4. Else declare the turn order (unless the user set one), open the beat, and
       hand to `Director.BeatDriver.advance/3` — the async walk that enqueues the
       first slot, or pauses for a user-controlled/assisted one (§A1/§A2).
    5. An empty cast means yield — nothing is enqueued, and the loop rests until
       the user acts.

  The beat loop is durable and distributed: the walk decision is a pure function
  (`Director.BeatWalk`), and each generation is its own retried job, so serial
  ordering falls out of enqueue-next-on-completion. Tests drive it synchronously
  under `Oban.Testing.with_testing_mode(:inline, …)`.
  """
  use Oban.Worker, queue: :director, max_attempts: 3

  require Logger

  alias Polyphony.App
  alias Polyphony.Director
  alias Polyphony.Director.{BeatDriver, BeatOps, BeatPolicy, Proposal}
  alias Polyphony.Director.Commands.OpenBeat

  @doc "Kick off (or resume) the beat loop for a scene."
  def enqueue(args) do
    args |> normalize() |> new() |> Oban.insert!()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    scene_id = args["scene_id"]
    beat = args["beat"]
    depth = args["depth"] || 0
    max_depth = args["max_depth"] || BeatPolicy.default_max_depth()

    members = BeatOps.members_now(scene_id, beat)

    case Director.decide(decide_opts(args, scene_id, beat, members)) do
      {:ok, resolved} ->
        BeatOps.author_world_events(resolved.world_events, scene_id, beat)

        drive(
          BeatOps.apply_membership_changes(resolved, scene_id, beat),
          resolved,
          args,
          scene_id,
          beat,
          depth,
          max_depth
        )

        :ok

      {:error, reason} ->
        # Director failure is the serious one (§12): retry with backoff, and if it
        # keeps failing fall back to yielding — never guess a cast.
        Logger.warning("director decision failed at beat #{beat}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Drive the outcome ────────────────────────────────────────────────────────

  defp drive(:changed, _resolved, args, scene_id, beat, depth, max_depth) do
    # Truncation (§10): re-decide against the new membership, subject to the cap.
    if depth + 1 < max_depth do
      enqueue(next_beat_args(args, scene_id, beat, depth))
    else
      Logger.info("beat #{beat}: truncated at depth cap; yielding")
    end
  end

  defp drive(:unchanged, %{cast: []}, _args, _scene_id, beat, _depth, _max_depth) do
    Logger.info("beat #{beat}: empty cast; yielding to user")
  end

  defp drive(:unchanged, resolved, args, scene_id, beat, depth, max_depth) do
    # Declare the turn order (unless the user already set one), open the beat, and
    # hand off to the walk — it enqueues the first slot, or pauses for a
    # user-controlled/assisted one (§A1/§A2).
    cast_ids = Enum.map(resolved.cast, & &1.character_id)
    order = BeatOps.declare_turn_order(scene_id, beat, cast_ids)

    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: BeatOps.beat_ref(scene_id, beat),
        scene_id: scene_id,
        beat: beat,
        cast: order
      })

    BeatDriver.advance(scene_id, beat,
      provider: args["provider"],
      depth: depth,
      max_depth: max_depth,
      control: resolved.control
    )
  end

  # ── Args ─────────────────────────────────────────────────────────────────────

  defp decide_opts(args, scene_id, beat, members) do
    [
      proposals: parse_proposals(args["proposals"]),
      options: parse_options(args["options"]),
      messages: [%{role: "system", content: "You are the Director. Cast and pace the scene."}],
      scene_id: scene_id,
      beat: beat,
      provider: BeatOps.resolve_provider(args["provider"]),
      cast_hint: members,
      control_hint: parse_control(args["control_hint"])
    ]
  end

  defp next_beat_args(args, scene_id, beat, depth) do
    args
    |> Map.merge(%{"scene_id" => scene_id, "beat" => beat + 1, "depth" => depth + 1})
    |> Map.drop([
      "chain",
      "beat_ref",
      "character_id",
      "packet_id",
      "remaining",
      "pacing_note",
      "control",
      "messages"
    ])
  end

  defp normalize(args) do
    args
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("beat", 1)
    |> Map.put_new("depth", 0)
  end

  defp parse_options(nil), do: %{exits: [], entities: []}

  defp parse_options(opts),
    do: %{exits: Map.get(opts, "exits", []), entities: Map.get(opts, "entities", [])}

  defp parse_proposals(nil), do: []

  defp parse_proposals(list) do
    Enum.map(list, fn p ->
      %Proposal{
        actor_id: p["actor_id"],
        type: parse_type(p["type"]),
        target: p["target"],
        detail: p["detail"]
      }
    end)
  end

  defp parse_type("exit"), do: :exit
  defp parse_type("interact"), do: :interact
  defp parse_type(_), do: :novel

  defp parse_control("continue"), do: :continue
  defp parse_control(:continue), do: :continue
  defp parse_control(_), do: :yield_to_user
end
