defmodule Polyphony.Fork do
  @moduledoc """
  Deliberate branching (§7) — the counterpart to a re-roll.

  A re-roll supersedes a turn *in place* on the same stream. A **fork** preserves
  the original untouched and starts an alternate timeline: a new, independent
  scene stream that shares the parent's history through `through_beat`, then
  diverges. This is the primitive behind "Branch from here", and the one an edit
  whose change invalidates a *later beat* reuses (the cross-beat case).

  **Copy-on-fork.** We copy the parent's canonical prefix into the new stream —
  re-pointing scene id and packet ids — rather than referencing it. The fork is
  then an ordinary open scene: membership, visibility, broadcast, scene-close, and
  re-roll all handle it unchanged, and it is fully isolated (editing or re-rolling
  the parent afterward can't bleed in, and vice-versa). Superseded packets are
  dropped from the copy — a fork inherits the canonical story, not its dead takes.
  """

  alias Polyphony.App
  alias PolyphonyCore.Packets
  alias Polyphony.Commands.ForkScene
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Events.{SceneOpened, SceneClosed}

  @doc """
  Fork `parent_scene_id` at `through_beat`, keeping events **through** that beat
  and diverging after. Returns `{:ok, new_scene_id}`.

  Opts: `:label` (branch label), `:new_scene_id` (override the generated id).
  """
  @spec fork(term(), integer(), keyword()) :: {:ok, term()} | {:error, :unknown_scene}
  def fork(parent_scene_id, through_beat, opts \\ []) do
    canonical = parent_scene_id |> BeatOps.stored_events() |> Packets.canonical()

    case canonical do
      [] ->
        {:error, :unknown_scene}

      events ->
        new_scene_id = opts[:new_scene_id] || gen_id(parent_scene_id)

        prefix =
          events
          |> Enum.filter(&keep?(&1, through_beat))
          |> Enum.map(&rewrite(&1, parent_scene_id, new_scene_id))

        :ok =
          App.dispatch(%ForkScene{
            scene_id: new_scene_id,
            parent_scene_id: parent_scene_id,
            fork_beat: through_beat,
            label: opts[:label],
            campaign_id: campaign_id(events),
            prefix: prefix
          })

        {:ok, new_scene_id}
    end
  end

  # ── Prefix selection ──────────────────────────────────────────────────────

  # Keep everything through `through_beat`; structural events without a beat
  # (a scene opening) are always part of the prefix.
  defp keep?(event, through_beat) do
    case event_beat(event) do
      nil -> true
      beat -> beat <= through_beat
    end
  end

  defp event_beat(%SceneOpened{opened_beat: b}), do: b
  defp event_beat(%SceneClosed{closed_beat: b}), do: b
  defp event_beat(event), do: Map.get(event, :beat)

  # ── Re-pointing events onto the new stream ────────────────────────────────

  defp rewrite(event, old_scene, new_scene) do
    event
    |> repoint_scene(new_scene)
    |> repoint_packet(old_scene, new_scene)
  end

  defp repoint_scene(event, new_scene) do
    if Map.has_key?(event, :scene_id), do: Map.put(event, :scene_id, new_scene), else: event
  end

  defp repoint_packet(event, old_scene, new_scene) do
    case Map.get(event, :packet_id) do
      id when is_binary(id) ->
        Map.put(event, :packet_id, String.replace_prefix(id, "#{old_scene}-", "#{new_scene}-"))

      _ ->
        event
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp campaign_id(events) do
    Enum.find_value(events, fn
      %SceneOpened{campaign_id: id} -> id
      _ -> nil
    end)
  end

  defp gen_id(parent_scene_id),
    do: "#{parent_scene_id}-fork-#{System.unique_integer([:positive])}"
end
