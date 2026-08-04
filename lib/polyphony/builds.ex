defmodule Polyphony.Builds do
  @moduledoc """
  Quick Build's progress, kept where the browser can't take it with it.

  ## Why this exists

  Quick Build used to run in the campaign LiveView's `start_async`. That task is linked
  to the socket, so the work died with the tab — and it dies *after* it has started
  writing. `QuickBuild.build/1` persists the world first, then each character, and the
  campaign association happened last, back in the LiveView. Navigate away halfway and
  the library keeps a world nothing points at, under exactly the name the author was
  about to use; the next attempt then refuses to save because that name is taken, and
  nothing on screen explains why.

  Two changes fix the class rather than the symptom. The work moves to an Oban job
  (`Polyphony.Jobs.QuickBuild`), so the socket is a viewer rather than the owner. And
  the job **associates as it goes** — the world is attached to the campaign the moment
  it exists — so an interrupted build leaves a half-built campaign, which is a thing
  you can look at and finish, rather than loose parts nothing references.

  ## What a row means

  One per campaign, `running` / `done` / `failed`, with a step count and the phase
  label. It is the answer to "is a build running?" for anyone who asks — the screen
  that started it, the same screen on a phone, or the screen after a reconnect. The
  LiveView reads it on mount and subscribes for the rest; it holds no build state of
  its own, because state a reconnect can't recover is state that will be lost.

  Progress is written **and** broadcast: the broadcast is the fast path, the row is the
  truth. A subscriber that missed messages catches up by reading, which is what makes
  reconnecting work at all.
  """

  alias Polyphony.ReadModels.BuildRun
  alias Polyphony.Repo

  @type t :: BuildRun.t()

  @doc "The PubSub topic carrying one campaign's build progress."
  @spec topic(term()) :: String.t()
  def topic(campaign_id), do: "campaign:#{campaign_id}:build"

  @doc "Subscribe the calling process to a campaign's build progress."
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(campaign_id) do
    Phoenix.PubSub.subscribe(Polyphony.PubSub, topic(campaign_id))
  rescue
    _ -> :ok
  end

  @doc "The current run for a campaign, or nil."
  @spec get(term(), keyword()) :: t() | nil
  def get(campaign_id, opts \\ []), do: BuildRun.get(repo(opts), campaign_id)

  @doc "Is a build under way for this campaign?"
  @spec running?(term(), keyword()) :: boolean()
  def running?(campaign_id, opts \\ []),
    do: match?(%BuildRun{status: "running"}, get(campaign_id, opts))

  @doc """
  Claim the campaign for a run, or `:taken` if one is already going.

  The claim is the guard against a double-tap and against two devices starting the
  same build — it is taken in the database rather than in the socket, because the
  socket is exactly the thing that can't be trusted to still be there.
  """
  @spec claim(term(), pos_integer(), keyword()) :: {:ok, t()} | :taken
  def claim(campaign_id, total, opts \\ []) do
    case BuildRun.claim(repo(opts), campaign_id, total) do
      {:ok, run} -> {:ok, announce(campaign_id, run)}
      :taken -> :taken
    end
  end

  @doc "Record a phase, as `QuickBuild`'s `:progress` callback shape."
  @spec progress(term(), map(), keyword()) :: :ok
  def progress(campaign_id, %{done: done, total: total, label: label}, opts \\ []) do
    put(campaign_id, %{step: done, total: total, label: label}, opts)
    :ok
  end

  @doc "Mark the run finished, with the sentence the screen shows for it."
  @spec finish(term(), String.t(), keyword()) :: :ok
  def finish(campaign_id, detail, opts \\ []) do
    put(campaign_id, %{status: "done", label: "Done", detail: detail}, opts)
    :ok
  end

  @doc """
  Mark the run failed.

  Failed rather than deleted: the author was probably not watching when it happened,
  and a build that vanishes without a word is indistinguishable from one that was
  never started.
  """
  @spec fail(term(), term(), keyword()) :: :ok
  def fail(campaign_id, reason, opts \\ []) do
    put(campaign_id, %{status: "failed", label: "Failed", detail: describe(reason)}, opts)
    :ok
  end

  @doc "Forget the run — the author has read the outcome and dismissed it."
  @spec clear(term(), keyword()) :: :ok
  def clear(campaign_id, opts \\ []) do
    BuildRun.delete(repo(opts), campaign_id)
    Phoenix.PubSub.broadcast(Polyphony.PubSub, topic(campaign_id), {:build_cleared, campaign_id})
    :ok
  rescue
    _ -> :ok
  end

  @doc "How far along, 0–100 — the fraction the progress bar draws."
  @spec percent(t() | nil) :: non_neg_integer()
  def percent(nil), do: 0
  def percent(%BuildRun{status: "done"}), do: 100

  def percent(%BuildRun{step: step, total: total}) when is_integer(total) and total > 0,
    do: min(100, round(step / total * 100))

  def percent(_), do: 0

  defp put(campaign_id, changes, opts) do
    case BuildRun.update(repo(opts), campaign_id, changes) do
      nil -> nil
      run -> announce(campaign_id, run)
    end
  end

  # Best-effort: a build must not fail because nobody was listening.
  defp announce(campaign_id, run) do
    Phoenix.PubSub.broadcast(Polyphony.PubSub, topic(campaign_id), {:build_progress, run})
    run
  rescue
    _ -> run
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe({:world_failed, reason}), do: "The world couldn't be written: #{describe(reason)}"
  defp describe(reason), do: inspect(reason)

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
