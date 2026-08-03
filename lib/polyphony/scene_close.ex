defmodule Polyphony.SceneClose do
  @moduledoc """
  The scene-close fan-out (§10) — the expensive, infrequent beat.

  On scene close it produces, for the scene:

    * **N+1 summaries** — omniscient + one per participant, each from that
      viewer's filtered stream (`Summarizer`) — embedded and stored keyed by
      character (`ReadModels.SceneSummary`, §8).
    * **Arc extraction** per participant (`ArcExtractor`) — proposed durable
      changes stored for review (`ReadModels.ArcEntry`, §6.2).

  ## Two ways to run it

  * `enqueue/2` — the production path (§10 "all Oban jobs"). Each summary and each
    participant's extraction is its own job (`Jobs.SummarizeScene`,
    `Jobs.ExtractArc`), so a **transient** failure backs off and retries per job,
    and a job that exhausts its attempts just leaves that one summary/arc missing.
  * `run/2` — the synchronous, best-effort path for offline/tests: same units,
    but failures are logged and skipped rather than retried.

  Either way it **degrades rather than fails (§12)** — scene entry never blocks on
  this, and a missing summary falls back to the character's filtered verbatim
  scene, which is already in the log.

  The per-unit functions (`summarize_viewer/3`, `extract_participant/3`) classify
  failures for the §12 table: summaries are transient (retry); a schema-invalid
  arc is permanent (cancel, don't loop); provider/transport errors retry.
  """

  require Logger

  alias Polyphony.{App, Embeddings, Repo, Packets}
  alias Polyphony.Costs.Attribution
  alias Polyphony.SceneClose.{Summarizer, ArcExtractor, WorldArcExtractor}
  alias Polyphony.ReadModels.{SceneSummary, ArcEntry}
  alias Polyphony.Events.{CharacterEntered, SceneOpened}
  alias Polyphony.Jobs.{SummarizeScene, ExtractArc, ExtractWorldArc}

  # ── Production path: fan out into retryable Oban jobs ─────────────────────────

  @doc """
  Enqueue the scene-close fan-out as individual Oban jobs (one per summary, one
  per participant's arc extraction). Options `:provider`/`:embedder` accept a
  module (passed to the jobs as a name). Returns the job counts.
  """
  @spec enqueue(term(), keyword()) :: {:ok, map()}
  def enqueue(scene_id, opts \\ []) do
    events = stored_events(scene_id)
    participants = participants(events)
    provider = mod_name(Keyword.get(opts, :provider))
    embedder = mod_name(Keyword.get(opts, :embedder))

    for key <- [SceneSummary.omniscient_key() | participants] do
      %{"scene_id" => scene_id, "viewer" => key, "provider" => provider, "embedder" => embedder}
      |> SummarizeScene.new()
      |> Oban.insert!()
    end

    for id <- participants do
      %{"scene_id" => scene_id, "character_id" => id, "provider" => provider}
      |> ExtractArc.new()
      |> Oban.insert!()
    end

    # World arc (§2.8): one extraction per scene, over the whole stream (not per
    # participant). The job no-ops if the scene has no campaign to attach it to.
    %{"scene_id" => scene_id, "provider" => provider}
    |> ExtractWorldArc.new()
    |> Oban.insert!()

    {:ok,
     %{
       participants: participants,
       summary_jobs: length(participants) + 1,
       arc_jobs: length(participants),
       world_arc_jobs: 1
     }}
  end

  # ── Synchronous best-effort path ─────────────────────────────────────────────

  @doc """
  Run the pipeline inline (no retries). Options: `:provider`, `:embedder`,
  `:repo`. Returns `{:ok, %{participants:, summaries:, arc_entries:}}`.
  """
  @spec run(term(), keyword()) :: {:ok, map()}
  def run(scene_id, opts \\ []) do
    participants = scene_id |> stored_events() |> participants()

    summaries =
      [SceneSummary.omniscient_key() | participants]
      |> Enum.map(&summarize_viewer(scene_id, viewer_from_key(&1), opts))
      |> Enum.count(&(&1 == :ok))

    arc_entries =
      participants
      |> Enum.map(fn id ->
        case extract_participant(scene_id, id, opts) do
          {:ok, n} -> n
          other -> log_degrade("arc", id, other)
        end
      end)
      |> Enum.sum()

    world_arc_entries =
      case extract_world(scene_id, opts) do
        {:ok, n} -> n
        other -> log_degrade("world_arc", scene_id, other)
      end

    {:ok,
     %{
       participants: participants,
       summaries: summaries,
       arc_entries: arc_entries,
       world_arc_entries: world_arc_entries
     }}
  end

  # ── Per-unit work (called by both paths) ─────────────────────────────────────

  @doc """
  Produce, embed, and store one viewer's summary. `:ok`, or `{:error, reason}`
  (transient — worth retrying).
  """
  @spec summarize_viewer(term(), :omniscient | {:character, term()}, keyword()) ::
          :ok | {:error, term()}
  def summarize_viewer(scene_id, viewer, opts) do
    repo = Keyword.get(opts, :repo) || Repo
    events = stored_events(scene_id)

    # Meter the summary embedding to the campaign owner (§B5), resolved from the scene.
    embed_opts =
      [embedder: Keyword.get(opts, :embedder), usage_kind: "embedding"] ++
        Map.to_list(Attribution.for_scene(scene_id))

    with {:ok, text} <- Summarizer.summarize(events, viewer, opts),
         {:ok, embedding} <- Embeddings.embed(text, embed_opts) do
      SceneSummary.put(repo, scene_id, viewer_key(viewer), text, embedding)
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Extract and store one participant's proposed arc entries. `{:ok, count}`,
  `{:cancel, reason}` for a permanent (schema-invalid) failure — don't loop — or
  `{:error, reason}` for a transient one — retry.
  """
  @spec extract_participant(term(), term(), keyword()) ::
          {:ok, non_neg_integer()} | {:cancel, term()} | {:error, term()}
  def extract_participant(scene_id, character_id, opts) do
    repo = Keyword.get(opts, :repo) || Repo
    events = stored_events(scene_id)

    ext_opts =
      opts
      |> Keyword.put(:source_scene_id, scene_id)
      |> meter(scene_id, "arc")

    case ArcExtractor.extract(events, character_id, ext_opts) do
      {:ok, entries} ->
        Enum.each(entries, &ArcEntry.put(repo, &1, character_id))
        {:ok, length(entries)}

      {:error, :invalid_arc} ->
        {:cancel, :invalid_arc}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Extract and store the scene's proposed **world** arc (§2.8) — one call per scene,
  over the whole stream, keyed to the campaign. `{:ok, count}`, `{:cancel, reason}`
  for a permanent (schema-invalid) failure, `{:error, reason}` for a transient one.
  Returns `{:ok, 0}` when the scene has no campaign to attach world arc to.
  """
  @spec extract_world(term(), keyword()) ::
          {:ok, non_neg_integer()} | {:cancel, term()} | {:error, term()}
  def extract_world(scene_id, opts \\ []) do
    repo = Keyword.get(opts, :repo) || Repo
    events = stored_events(scene_id)
    {campaign_id, location_id} = scene_setup(events)

    if is_nil(campaign_id) do
      {:ok, 0}
    else
      ext_opts =
        opts
        |> Keyword.put(:source_scene_id, scene_id)
        |> Keyword.put(:location_id, location_id)
        |> meter(scene_id, "world_arc")

      case WorldArcExtractor.extract(events, ext_opts) do
        {:ok, entries} ->
          Enum.each(entries, &ArcEntry.put_world(repo, &1, campaign_id))
          {:ok, length(entries)}

        {:error, :invalid_arc} ->
          {:cancel, :invalid_arc}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, e}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @doc "Turn a stored viewer key back into a viewer value."
  def viewer_from_key(key) do
    if key == SceneSummary.omniscient_key(), do: :omniscient, else: {:character, key}
  end

  defp viewer_key(:omniscient), do: SceneSummary.omniscient_key()
  defp viewer_key({:character, id}), do: to_string(id)

  defp log_degrade(kind, id, result) do
    Logger.warning("scene-close #{kind} degraded for #{inspect(id)}: #{inspect(result)}")
    0
  end

  defp mod_name(nil), do: nil
  defp mod_name(mod) when is_atom(mod), do: to_string(mod)
  defp mod_name(str) when is_binary(str), do: str

  defp participants(events) do
    events
    |> Enum.flat_map(fn
      %CharacterEntered{character_id: id} -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  # Attribute an extraction LLM call to the campaign owner (§B5) — for now the owner
  # owns everything autonomous in their campaign. `put_new` so an explicit caller
  # (a test) still wins. A campaign with no user owner resolves to nil user_id, and
  # the metered call then records nothing rather than failing.
  defp meter(opts, scene_id, usage_kind) do
    attr = Attribution.for_scene(scene_id)

    opts
    |> Keyword.put_new(:user_id, attr.user_id)
    |> Keyword.put_new(:campaign_id, attr.campaign_id)
    |> Keyword.put_new(:usage_kind, usage_kind)
  end

  # The scene's campaign + authored location, from its opening event.
  defp scene_setup(events) do
    case Enum.find(events, &match?(%SceneOpened{}, &1)) do
      %SceneOpened{campaign_id: c, location_id: l} -> {c, l}
      _ -> {nil, nil}
    end
  end

  # Canonical view only: re-rolled packets are never summarized or mined for arcs.
  defp stored_events(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Packets.canonical()
  rescue
    _ -> []
  end
end
