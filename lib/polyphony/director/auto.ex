defmodule Polyphony.Director.Auto do
  @moduledoc """
  A scene left to run itself — the beat loop without the hand-back.

  ## Why

  Continue advances one beat and yields. That is right for playing and useless for the
  thing that needs a *finished* scene to look at: arc review has nothing to review until
  a scene has run long enough to change somebody, and getting there meant tapping
  Continue thirty times.

  Mechanically this is the loop that already exists. The Director chains beats by itself
  (`BeatPolicy.next/1` → `:continue`); what stops it every time is the `yield_to_user`
  hint Continue sends and the three-beat depth cap. An auto run drops the hint, raises
  the cap, and adds the stopping rules a human was standing in for.

  ## Where it stops

  Three ends, checked before every beat, in this order:

    * **The Director closed the scene.** Its `scene_action: :close` dispatches
      `CloseScene`, and that is the only "the story is over" signal the decision
      contract has. The scene's own aggregate refuses further work anyway; this stops
      the loop asking.
    * **The room emptied.** No members at this beat — everyone exited, or a `:move`
      scene action carried them somewhere else. A Director casting from an empty roster
      writes nothing, forever.
    * **The beat cap.** 50 by default. Not a guess about story length: a bound on what
      one tap can spend, and the reason the button is safe to press.

  A **location change** is deliberately not a fourth rule, and this is the honest place
  to say so: `location_id` is set once on `SceneOpened` and no event changes it, so
  there is nothing to observe. The Director relocating people is a `:move`, which exits
  them — the second rule covers it. A genuine mid-scene relocation would need an event
  first.

  ## Pause

  The run is a row rather than job args because a pause is a fact about the *scene*, not
  about whichever job happens to be in flight. Checked at the top of every beat, so
  pausing takes effect at the next boundary rather than tearing up work already paid
  for. Resuming enqueues from where the row says it got to.

  Every transition is written **and** broadcast — the broadcast is the fast path, the
  row is the truth, so a screen that missed messages catches up by reading. Same
  contract as `Polyphony.Builds`.
  """

  require Logger

  alias Polyphony.Director.BeatOps
  alias Polyphony.Events.SceneClosed
  alias Polyphony.Jobs.RunBeat
  alias Polyphony.ReadModels.AutoRun
  alias Polyphony.Repo

  @type t :: AutoRun.t()
  @type stop :: :closed | :empty | :cap

  @default_max_beats 50

  @doc "The default beat cap — what one tap on Auto is allowed to spend."
  @spec default_max_beats() :: pos_integer()
  def default_max_beats, do: @default_max_beats

  @doc "The PubSub topic carrying one scene's auto-run state."
  @spec topic(term()) :: String.t()
  def topic(scene_id), do: "scene:#{scene_id}:auto"

  @doc "Subscribe the calling process to a scene's auto-run state."
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(scene_id) do
    Phoenix.PubSub.subscribe(Polyphony.PubSub, topic(scene_id))
  rescue
    _ -> :ok
  end

  @doc "The run for a scene, or nil."
  @spec get(term(), keyword()) :: t() | nil
  def get(scene_id, opts \\ []), do: AutoRun.get(repo(opts), scene_id)

  @doc "Is this scene running itself right now?"
  @spec running?(term(), keyword()) :: boolean()
  def running?(scene_id, opts \\ []),
    do: match?(%AutoRun{status: "running"}, get(scene_id, opts))

  @doc """
  Start a run at `beat`, and enqueue its first beat.

  `{:error, :taken}` when one is already going — the unique index is the guard, so two
  taps that race can't put two Directors on the same transcript.
  """
  @spec start(term(), integer(), keyword()) :: {:ok, t()} | {:error, :taken}
  def start(scene_id, beat, opts \\ []) do
    max_beats = Keyword.get(opts, :max_beats, @default_max_beats)

    case AutoRun.claim(repo(opts), scene_id, max_beats, beat) do
      {:ok, run} ->
        enqueue(scene_id, beat, max_beats, opts)
        {:ok, announce(run)}

      :taken ->
        {:error, :taken}
    end
  end

  @doc """
  Pause a running scene. Takes effect at the next beat boundary.

  Deliberately not a cancellation of the job in flight: that beat is already generating,
  and throwing it away would cost the same money to produce nothing.
  """
  @spec pause(term(), keyword()) :: {:ok, t()} | {:error, :not_running}
  def pause(scene_id, opts \\ []) do
    case get(scene_id, opts) do
      %AutoRun{status: "running"} ->
        {:ok, announce(AutoRun.set_status(repo(opts), scene_id, "paused"))}

      _ ->
        {:error, :not_running}
    end
  end

  @doc "Resume a paused scene from where it got to, and enqueue the next beat."
  @spec resume(term(), integer(), keyword()) :: {:ok, t()} | {:error, :not_paused}
  def resume(scene_id, beat, opts \\ []) do
    case get(scene_id, opts) do
      %AutoRun{status: "paused"} ->
        run = AutoRun.set_status(repo(opts), scene_id, "running")
        enqueue(scene_id, beat, remaining(run), opts)
        {:ok, announce(run)}

      _ ->
        {:error, :not_paused}
    end
  end

  @doc "End a run — the author stopping it, or the loop reaching one of its three ends."
  @spec finish(term(), stop() | String.t(), keyword()) :: t() | nil
  def finish(scene_id, reason, opts \\ []) do
    announce(AutoRun.set_status(repo(opts), scene_id, "done", reason_text(reason)))
  end

  @doc "Record that a beat ran, and return the updated row (nil if the run is gone)."
  @spec note_beat(term(), integer(), keyword()) :: t() | nil
  def note_beat(scene_id, beat, opts \\ []),
    do: announce(AutoRun.advance(repo(opts), scene_id, beat))

  @doc """
  May the loop run `beat` for this scene?

  `:ok`, or `{:stop, reason}` with the rule that ended it — `nil` reason means the run
  is simply not there or not running (paused, finished, never started), which is not an
  ending and needs no announcement.
  """
  @spec check(term(), integer(), keyword()) :: :ok | {:stop, stop() | nil}
  def check(scene_id, beat, opts \\ []) do
    case get(scene_id, opts) do
      %AutoRun{status: "running"} = run ->
        cond do
          run.beats_run >= run.max_beats -> {:stop, :cap}
          closed?(scene_id) -> {:stop, :closed}
          BeatOps.members_now(scene_id, beat) == [] -> {:stop, :empty}
          true -> :ok
        end

      _ ->
        {:stop, nil}
    end
  end

  @doc "How many beats this run has left."
  @spec remaining(t() | nil) :: non_neg_integer()
  def remaining(%AutoRun{beats_run: run, max_beats: cap})
      when is_integer(run) and is_integer(cap),
      do: max(cap - run, 0)

  def remaining(_), do: 0

  @doc "The sentence a screen shows for a finished run."
  @spec reason_text(stop() | String.t() | nil) :: String.t() | nil
  def reason_text(:closed), do: "The Director closed the scene."
  def reason_text(:empty), do: "Everyone has left."
  def reason_text(:cap), do: "Reached the beat limit."
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(_), do: nil

  # ── Internals ────────────────────────────────────────────────────────────────

  # `"auto"` rides the args so a self-chained beat stays an auto beat, and the control
  # hint is `"auto"` rather than a control: it says *how this run was started*, which is
  # what `RunBeat` needs to decide whether the Director's `yield_to_user` ends anything.
  defp enqueue(scene_id, beat, max_beats, opts) do
    enqueue = Keyword.get(opts, :enqueue, &RunBeat.enqueue/1)

    enqueue.(%{
      "scene_id" => scene_id,
      "beat" => beat,
      "auto" => true,
      "control_hint" => "auto",
      "depth" => 0,
      "max_depth" => max(max_beats, 1)
    })
  end

  defp closed?(scene_id) do
    scene_id |> BeatOps.stored_events() |> Enum.any?(&match?(%SceneClosed{}, &1))
  rescue
    _ -> false
  end

  defp announce(nil), do: nil

  defp announce(%AutoRun{} = run) do
    Phoenix.PubSub.broadcast(Polyphony.PubSub, topic(run.scene_id), {:scene_auto, run})
    run
  rescue
    _ -> run
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
