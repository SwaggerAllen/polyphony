defmodule Polyphony.SceneReset do
  @moduledoc """
  The clean-slate wipe the character-identity flip requires (§5.2).

  ## Why this exists, and why it isn't a backfill

  Before the flip, `character_id` in the event log was a character's **display
  name**; now it is their library id. Every scene stream written under the old
  scheme keys membership, packet ids, whisper `addressed_to` and arc on names, and
  mixing the two schemes in one deployment is worse than either: a scene half-keyed
  would have members the guards don't recognise and whispers that reach nobody.

  A migration is not available. **Events are immutable** (rule 6) — rewriting
  `character_id` in place would mean rewriting history, which is the one thing an
  event-sourced system may never do. The legacy-tolerant fallbacks in `Scene.Cast`
  and `Rebuild.sheet_for` keep old streams *readable*, but readable is not the same
  as safe to keep playing.

  So the decision recorded in the backlog is a clean slate: drop the scenes, keep
  the library. Characters, worlds and campaigns are authored work and survive
  untouched; scenes are play, and at this stage of the project there is no play
  worth more than a coherent identity model.

  ## What it removes

  Everything derived from a scene stream, and nothing else:

    * every event stream (the event store's own tables, dev/prod alike);
    * the scene-derived read models — memberships, per-character scene summaries,
      arc entries, generation failures, packet drafts, fork lineage;
    * each campaign's `scenes` list, so the UI stops linking to streams that are
      gone.

  Library entries — characters, worlds, campaigns themselves — are **kept**, along
  with accounts, cost ledgers, moderation and notifications.

  ## Running it

      # dev
      mix scene.reset --yes

      # prod, from the release
      bin/polyphony eval "Polyphony.SceneReset.run!()"

  It is deliberately not wired to boot or to a deploy step: it destroys play, and
  that should take a person deciding to type it.
  """
  require Logger

  import Ecto.Query, only: [from: 2]

  alias Polyphony.{Library, Repo}
  alias Polyphony.ReadModels.LibraryEntry

  # Scene-derived read models, in an order that respects nothing in particular —
  # none of them reference each other.
  @scene_tables ~w(
    scene_memberships
    character_scene_summaries
    arc_entries
    generation_failures
    packet_drafts
    scene_forks
    projection_versions
  )

  @doc """
  Wipe every scene and everything derived from one. Returns a summary map.

  Raises rather than half-finishing: a partial wipe would leave exactly the mixed
  state this exists to avoid.

  `streams: false` skips the event store and clears only the derived read models and
  campaign scene lists. That's for the suite, which configures a persistent event
  store for its own end-to-end test — resetting it mid-run would pull the rug from
  under an unrelated test. Real runs take the default.
  """
  @spec run!(keyword()) :: %{
          streams: :ok | :skipped,
          rows: %{String.t() => integer()},
          campaigns: integer()
        }
  def run!(opts \\ []) do
    Logger.warning("[scene.reset] wiping all scenes — library entries are kept")

    result = %{
      streams: reset_event_store!(Keyword.get(opts, :streams, true)),
      rows: Map.new(@scene_tables, &{&1, truncate!(&1)}),
      campaigns: clear_campaign_scenes!()
    }

    Logger.warning("[scene.reset] done: #{inspect(result)}")
    result
  end

  # With no persistent store configured — dev, where the event store is Commanded's
  # in-memory adapter — there is nothing on disk to drop and a restart empties it. In
  # prod it's the `eventstore` schema in the shared database, emptied in place:
  # `reset!/3` truncates the stream tables and restarts their sequences, leaving the
  # schema and its migration history alone. Dropping the database is not an option —
  # the read models live in it.
  defp reset_event_store!(false), do: :skipped

  defp reset_event_store!(true) do
    case Application.get_env(:polyphony, :event_stores, []) do
      [] ->
        Logger.info("[scene.reset] no persistent event store — streams vanish on restart")
        :skipped

      stores ->
        Application.ensure_all_started(:postgrex)

        for store <- stores do
          config = Keyword.put(store.config(), :pool_size, 2)
          {:ok, conn} = Postgrex.start_link(config)

          try do
            EventStore.Storage.Initializer.reset!(conn, config)
          after
            GenServer.stop(conn)
          end
        end

        :ok
    end
  end

  # Counted before truncating, so the summary reports what was actually destroyed.
  defp truncate!(table) do
    %{rows: [[count]]} = Repo.query!(~s|SELECT count(*) FROM "#{table}"|)
    Repo.query!(~s|TRUNCATE TABLE "#{table}" RESTART IDENTITY|)
    count
  end

  # A campaign payload carries the scene ids it opened. Those streams are gone, so
  # the list has to go too or the overview links into nothing.
  #
  # **Frozen snapshots are left alone.** They share the `"campaign"` kind, but their
  # `scenes` is a frozen record of what was published rather than a link into a live
  # stream — blanking it would empty the contents list and the reading position of
  # every reader who has one, to fix a dangling link that isn't there.
  defp clear_campaign_scenes! do
    from(e in LibraryEntry, where: e.kind == "campaign" and e.frozen == false)
    |> Repo.all()
    |> Enum.count(fn entry ->
      case Library.payload(entry) do
        %{scenes: scenes} = payload when scenes != [] ->
          {:ok, _} = Library.update_payload(entry.id, %{payload | scenes: []})
          true

        _ ->
          false
      end
    end)
  end
end
