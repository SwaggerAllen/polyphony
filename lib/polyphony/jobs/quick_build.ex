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

  ## Retries, and why they had to be earned

  This shipped with `max_attempts: 1`. The reasoning was that a retry would re-run every
  provider call, charge for them again, and leave the campaign with two worlds and two
  casts — all true of the job as it was then. But that is an argument for fixing the
  retry, not for abandoning the longest and most expensive operation in the app to its
  first transient failure. A build is minutes of work and a real bill; a 502 four
  characters in is exactly the thing retries exist for.

  So the build **resumes**. Everything it writes is associated to the campaign the moment
  it exists, and the run row records which seeds have been written — recorded at the
  write, not at the end of the seed, so a crash on either side of it resolves correctly.
  An attempt picks up with the world it already has, the seeds it hasn't done, and the
  covers it hasn't written. `max_attempts: 3` on Oban's default backoff.

  What a retry never does is duplicate. That is worth more than finishing: a second
  Wren in the cast is a mess an author has to notice and unpick, while a missing one is
  a button away.

  Uniqueness is enforced twice on purpose: Oban refuses a duplicate job while one is
  enqueued or running, and `Builds.claim/2` refuses a duplicate run in the database.
  The second is the one that holds, because it is the one a node restart can't forget.
  """
  use Oban.Worker, queue: :generation, max_attempts: 3

  require Logger

  alias Polyphony.{Builds, Campaigns, Library, Owner}
  alias Polyphony.Authoring.{QuickBuild, Stub}

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

    args = %{
      "campaign_id" => to_string(campaign_id),
      "owner" => Owner.key(Owner.coerce(Keyword.fetch!(opts, :owner))),
      "world_seed" => to_string(Keyword.get(opts, :world_seed, "")),
      "character_seeds" => Enum.map(seeds, &to_string/1),
      "suggest_offscreen" => !!Keyword.get(opts, :suggest_offscreen, false),
      "groups" => !!Keyword.get(opts, :groups, false),
      "user_id" => opts[:user_id] && to_string(opts[:user_id]),
      "provider" => opts[:provider] && to_string(opts[:provider]),
      # Who was in the cast *before* this build, so a resumed attempt can tell its own
      # characters from ones that were already there. Quick Build is first-run only
      # today, so this is normally empty — recording it anyway means the resume logic
      # doesn't quietly depend on that staying true.
      "baseline_characters" => baseline_characters(campaign_id)
    }

    # The phases `Authoring.QuickBuild` reports: world, one per character, linking,
    # premise, covers, done. The args are stored on the run so a build that exhausts its
    # attempts can be started again from the screen — a failed build leaves a campaign
    # that is no longer first-run, so the card offering Quick Build is gone and there
    # would otherwise be no way back to it.
    case Builds.claim(campaign_id, length(seeds) + 4, args) do
      :taken ->
        :taken

      {:ok, run} ->
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

  @doc """
  Start a failed build again, from the arguments it was started with.

  Not a fresh build: the claim keeps the campaign's existing `done` list, so this picks
  up where the attempts left off rather than paying for the world and cast twice.
  """
  @spec retry(term()) :: {:ok, Builds.t()} | :taken | {:error, term()}
  def retry(campaign_id) do
    case Builds.args(campaign_id) do
      nil ->
        {:error, :no_run}

      args ->
        case Builds.resume(campaign_id) do
          :taken -> :taken
          {:ok, run} -> with {:ok, _} <- Oban.insert(new(args)), do: {:ok, run}
        end
    end
  end

  defp baseline_characters(campaign_id) do
    case Library.get(campaign_id) do
      nil -> []
      entry -> (Library.payload(entry) || %{})[:character_ids] || []
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    %{"campaign_id" => campaign_id} = args
    owner = Owner.parse(args["owner"])

    opts =
      [
        owner: owner,
        world_seed: args["world_seed"],
        character_seeds: args["character_seeds"] || [],
        suggest_offscreen: args["suggest_offscreen"] == true,
        groups: args["groups"] == true,
        campaign_id: campaign_id,
        progress: &Builds.progress(campaign_id, &1),
        on_entry: &associate(campaign_id, &1),
        on_seed_done: &Builds.seed_done(campaign_id, &1),
        resume: resume_state(campaign_id, args)
      ] ++ meter(args)

    case QuickBuild.build(opts) do
      {:ok, result} ->
        attach_premise(campaign_id, result[:premise])
        attach_name(campaign_id, result[:name])
        Builds.finish(campaign_id, summary(result))
        :ok

      {:error, reason} ->
        Logger.warning(
          "[quick_build] campaign=#{campaign_id} attempt #{attempt}/#{max} failed: " <>
            inspect(reason)
        )

        if attempt < max do
          # Leave the run *running*: another attempt is coming, and telling the author it
          # failed only to start again is worse than saying nothing.
          {:error, reason}
        else
          Builds.fail(campaign_id, reason)
          :ok
        end
    end
  end

  # What this campaign already has from earlier attempts. Read from the campaign and the
  # run rather than carried in the job args, because args are fixed at enqueue and the
  # question is what happened *since*.
  defp resume_state(campaign_id, args) do
    run = Builds.get(campaign_id)
    payload = campaign_payload(campaign_id)
    baseline = MapSet.new(args["baseline_characters"] || [])

    %{
      bible: payload[:bible_id] && Library.get(payload[:bible_id]),
      done: (run && run.done) || [],
      # **Cast only.** The roster now also holds the off-screen stubs this build wrote,
      # and handing those back as built cast would have the resume treat them as seeds
      # already done — miscounting the walk, cross-linking walk-ons into the main cast,
      # and writing them covers they are not meant to have. `:full` is the discriminator
      # the build itself sets: a generated cast member is full, a stub is not.
      characters:
        (payload[:character_ids] || [])
        |> Enum.reject(&MapSet.member?(baseline, &1))
        |> Enum.map(&Library.get/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&Stub.full?(Library.payload(&1)))
    }
  end

  defp campaign_payload(campaign_id) do
    case Library.get(campaign_id) do
      nil -> %{}
      entry -> Library.payload(entry) || %{}
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

  # Cast and walk-ons join the same roster — `character_ids` is who is in this story, and
  # a stub invented by one of its characters is one of its people. Tier is what separates
  # them on screen (`:incidental`), not membership. Shared with the editor and play, which
  # both invent people the same way.
  defp associate(campaign_id, {kind, entry}) when kind in [:character, :stub],
    do: Campaigns.cast(campaign_id, entry.id)

  # Groups need no association step, and the clause exists to say so rather than to
  # fall through a catch-all. They are owner-scoped and the campaign screen lists them
  # from the owner (`Groups.list/1`), so a group is reachable the moment it is written —
  # there is no state in which one is orphaned the way an unattached world would be.
  # `world_bible_id` is the tie it does carry, set at the write.
  defp associate(_campaign_id, {:group, _entry}), do: :ok

  defp attach_premise(_campaign_id, premise) when premise in [nil, ""], do: :ok

  defp attach_premise(campaign_id, premise),
    do: update(campaign_id, &Map.put(&1, :premise, premise))

  # **Only into a blank.** A campaign the author already titled keeps its title — Quick
  # Build fills the gaps it was asked to fill, and renaming somebody's story out from
  # under them is not one of them. Everything else here is additive for the same reason.
  defp attach_name(_campaign_id, name) when name in [nil, ""], do: :ok

  defp attach_name(campaign_id, name) do
    update(campaign_id, fn payload ->
      if String.trim(to_string(payload[:name] || "")) == "",
        do: Map.put(payload, :name, name),
        else: payload
    end)
  end

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
