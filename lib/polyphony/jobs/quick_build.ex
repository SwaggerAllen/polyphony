defmodule Polyphony.Jobs.QuickBuild do
  @moduledoc """
  Quick Build, as a job the browser doesn't own.

  It used to run in the campaign LiveView's `start_async`. That task is linked to the
  socket, so a build that takes minutes and costs real money depended on a tab staying
  in the foreground — and it doesn't fail cleanly when the tab goes, it fails *part
  way through writing*. `Authoring.QuickBuild` persists the world, then each character,
  and the association back onto the campaign happened last, in the LiveView. Navigating
  away therefore left a world in the library that nothing pointed at, under the name
  the author had just used; the next attempt collided with it and the world editor
  refused to save with no visible explanation.

  Two things move here, and both matter:

    * **The work leaves the socket.** Progress is a `Polyphony.Builds` row, so it
      survives a reconnect, shows up on a second device, and is still there after the
      author closes the laptop. The LiveView subscribes and renders; it owns none of it.

    * **Association happens as the build goes**, via `:on_entry`. The world is attached
      to the campaign the moment it exists and each character is cast the moment it is
      written. An interrupted build then leaves a *half-built campaign* — something you
      can open, look at, and finish — instead of loose parts in a library with no clue
      where they came from.

  ## No retries

  `max_attempts: 1`, which is deliberate and is not the usual answer for a job. A retry
  would re-run the whole generation: dozens of provider calls, charged again, producing
  a second world and a second cast on top of the ones the first attempt already
  associated. Oban's retry exists to make transient failures invisible, and this
  failure is neither transient nor invisible — the campaign keeps whatever got built,
  the run row says what went wrong, and starting again is the author's call because
  they are the one paying for it.

  Uniqueness is enforced twice on purpose: Oban refuses a duplicate job while one is
  enqueued or running, and `Builds.claim/2` refuses a duplicate run in the database.
  The second is the one that holds, because it is the one a node restart can't forget.
  """
  use Oban.Worker, queue: :generation, max_attempts: 1

  require Logger

  alias Polyphony.{Builds, Library, Owner}
  alias Polyphony.Authoring.QuickBuild

  @doc """
  Enqueue a build for `campaign_id`. Returns `{:ok, run}`, or `:taken` when one is
  already under way for this campaign.

  The claim is taken *before* the job is inserted, so the screen can say "already
  building" without waiting for a queue round-trip — and so a double-tap loses on the
  unique index rather than on whichever handler happened to run second.
  """
  @spec enqueue(keyword()) :: {:ok, Builds.t()} | :taken | {:error, term()}
  def enqueue(opts) do
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    seeds = opts |> Keyword.get(:character_seeds, []) |> List.wrap()

    # The phases `Authoring.QuickBuild` reports: world, one per character, linking,
    # premise, covers, done.
    case Builds.claim(campaign_id, length(seeds) + 4) do
      :taken ->
        :taken

      {:ok, run} ->
        args = %{
          "campaign_id" => to_string(campaign_id),
          "owner" => Owner.key(Owner.coerce(Keyword.fetch!(opts, :owner))),
          "world_seed" => to_string(Keyword.get(opts, :world_seed, "")),
          "character_seeds" => Enum.map(seeds, &to_string/1),
          "suggest_offscreen" => !!Keyword.get(opts, :suggest_offscreen, false),
          "user_id" => opts[:user_id] && to_string(opts[:user_id]),
          "provider" => opts[:provider] && to_string(opts[:provider])
        }

        case Oban.insert(new(args)) do
          {:ok, _job} ->
            {:ok, run}

          {:error, reason} ->
            # The claim is ours and nothing is going to run against it, so hand it back
            # rather than leaving the campaign looking permanently mid-build.
            Builds.fail(campaign_id, reason)
            {:error, reason}
        end
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"campaign_id" => campaign_id} = args
    owner = Owner.parse(args["owner"])

    opts =
      [
        owner: owner,
        world_seed: args["world_seed"],
        character_seeds: args["character_seeds"] || [],
        suggest_offscreen: args["suggest_offscreen"] == true,
        campaign_id: campaign_id,
        progress: &Builds.progress(campaign_id, &1),
        on_entry: &associate(campaign_id, &1)
      ] ++ meter(args)

    case QuickBuild.build(opts) do
      {:ok, result} ->
        attach_premise(campaign_id, result[:premise])
        Builds.finish(campaign_id, summary(result))
        :ok

      {:error, reason} ->
        Logger.warning("[quick_build] campaign=#{campaign_id} failed: #{inspect(reason)}")
        Builds.fail(campaign_id, reason)
        {:error, reason}
    end
  end

  # ── Associating as we go ──────────────────────────────────────────────────────
  #
  # The whole reason this job exists. Each write is a read-modify-write on the
  # campaign's payload, which is safe enough here because the unique claim means only
  # one build touches a campaign at a time, and the fields it sets are ones the
  # campaign screen doesn't write while a build is running.

  defp associate(campaign_id, {:world, entry}) do
    update(campaign_id, fn payload -> Map.put(payload, :bible_id, entry.id) end)
  end

  defp associate(campaign_id, {:character, entry}) do
    update(campaign_id, fn payload ->
      ids = payload[:character_ids] || []
      Map.put(payload, :character_ids, Enum.uniq(ids ++ [entry.id]))
    end)
  end

  defp attach_premise(_campaign_id, premise) when premise in [nil, ""], do: :ok

  defp attach_premise(campaign_id, premise),
    do: update(campaign_id, &Map.put(&1, :premise, premise))

  defp update(campaign_id, fun) do
    case Library.get(campaign_id) do
      nil ->
        :ok

      entry ->
        Library.update_payload(entry.id, fun.(Library.payload(entry)))
        :ok
    end
  end

  defp summary(result) do
    n = length(result[:characters] || [])
    failed = length(result[:failed] || [])

    base = "Built a world, #{n} character(s), and a premise."
    if failed > 0, do: base <> " #{failed} character(s) couldn't be written.", else: base
  end

  defp meter(args) do
    [user_id: user_id(args["user_id"]), provider: provider(args["provider"])]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Back to an integer. Job args round-trip through JSON and the id went in as a string
  # for that reason, but `Costs.Ledger.user_id` is an `:id` — handed a string it silently
  # declines to record, so every quick-built generation would have gone unattributed
  # while the build itself looked perfectly healthy.
  defp user_id(nil), do: nil

  defp user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> id
    end
  end

  defp user_id(id), do: id

  # Args round-trip through JSON, so a module override comes back as a string. Only an
  # already-loaded module resolves — an unknown one falls back to the configured
  # provider rather than minting an atom from job args.
  defp provider(nil), do: nil

  defp provider(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
