defmodule Polyphony.SceneClose do
  @moduledoc """
  The scene-close fan-out (§10) — the expensive, infrequent beat.

  On scene close it produces, for the scene:

    * **N+1 summaries** — omniscient + one per participant, each from that
      viewer's filtered stream (`Summarizer`) — embedded and stored keyed by
      character (`ReadModels.SceneSummary`, §8).
    * **Arc extraction** per participant (`ArcExtractor`) — proposed durable
      changes stored for review (`ReadModels.ArcEntry`, §6.2).

  **Degrades rather than fails (§12).** Each summary/extraction is best-effort: a
  failed one is logged and skipped, never aborting the pipeline, and scene entry
  must not block on this — a missing summary just falls back to the character's
  filtered verbatim scene, which is already in the log.
  """

  require Logger

  alias Polyphony.{App, Repo}
  alias Polyphony.SceneClose.{Summarizer, ArcExtractor, Embedder}
  alias Polyphony.ReadModels.{SceneSummary, ArcEntry}
  alias Polyphony.Events.CharacterEntered

  @doc """
  Run the pipeline for `scene_id`. Options: `:provider`, `:embedder`, `:repo`.
  Returns `{:ok, %{participants:, summaries:, arc_entries:}}`.
  """
  @spec run(term(), keyword()) :: {:ok, map()}
  def run(scene_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    embedder = Keyword.get(opts, :embedder, Embedder.default())
    events = stored_events(scene_id)
    participants = participants(events)

    summaries =
      [:omniscient | Enum.map(participants, &{:character, &1})]
      |> Enum.map(&summarize_and_store(&1, scene_id, events, repo, embedder, opts))
      |> Enum.count(&(&1 == :ok))

    arc_count =
      participants
      |> Enum.map(&extract_and_store(&1, scene_id, events, repo, opts))
      |> Enum.sum()

    {:ok, %{participants: participants, summaries: summaries, arc_entries: arc_count}}
  end

  # ── Summaries ────────────────────────────────────────────────────────────────

  defp summarize_and_store(viewer, scene_id, events, repo, embedder, opts) do
    key = viewer_key(viewer)

    with {:ok, text} <- Summarizer.summarize(events, viewer, opts),
         {:ok, embedding} <- embedder.embed(text) do
      SceneSummary.put(repo, scene_id, key, text, embedding)
      :ok
    else
      other ->
        Logger.warning(
          "scene-close summary failed for #{key}@#{inspect(scene_id)}: #{inspect(other)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning("scene-close summary crashed for #{viewer_key(viewer)}: #{inspect(e)}")
      :error
  end

  defp viewer_key(:omniscient), do: SceneSummary.omniscient_key()
  defp viewer_key({:character, id}), do: to_string(id)

  # ── Arc extraction ───────────────────────────────────────────────────────────

  defp extract_and_store(character_id, scene_id, events, repo, opts) do
    case ArcExtractor.extract(events, character_id, Keyword.put(opts, :source_scene_id, scene_id)) do
      {:ok, entries} ->
        Enum.each(entries, &ArcEntry.put(repo, &1, character_id))
        length(entries)

      other ->
        Logger.warning("arc extraction failed for #{character_id}: #{inspect(other)}")
        0
    end
  rescue
    e ->
      Logger.warning("arc extraction crashed for #{character_id}: #{inspect(e)}")
      0
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp participants(events) do
    events
    |> Enum.flat_map(fn
      %CharacterEntered{character_id: id} -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp stored_events(scene_id) do
    App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)
  rescue
    _ -> []
  end
end
