defmodule Polyphony.ReadModels.AutoRun do
  @moduledoc """
  One row per scene that has been left to run itself — how far it got, and why it
  stopped.

  Workflow state, not fiction: like `PacketDraft`, `BuildRun` and the failures table it
  is deliberately **off** the event log, so `Visibility` can never see it and a replay
  never re-runs a scene. The unique index on `scene_id` is the concurrency control, not
  tidiness — see the migration.
  """
  use Ecto.Schema

  import Ecto.Query

  @type t :: %__MODULE__{}

  schema "scene_auto_runs" do
    field(:scene_id, :string)
    field(:status, :string, default: "running")
    field(:beats_run, :integer, default: 0)
    field(:max_beats, :integer, default: 50)
    field(:beat, :integer)
    field(:ended_reason, :string)
    timestamps(type: :naive_datetime_usec)
  end

  @spec get(Ecto.Repo.t(), term()) :: t() | nil
  def get(repo, scene_id) do
    sid = to_string(scene_id)
    repo.one(from(r in __MODULE__, where: r.scene_id == ^sid))
  end

  @doc """
  Claim the scene for a new run, or `:taken` if one is already going.

  An upsert rather than a get-then-insert: two taps on Auto race to the database
  together, and only the one whose `ON CONFLICT` clause matched a not-running row comes
  back with a claim. A second loop into the same transcript is not a tidiness problem —
  two Directors would be casting the same beat.

  A finished or paused run is *restartable*: the counters reset, because "run this scene
  for fifty beats" is what the button says and picking up an old count would silently
  make it fewer.
  """
  @spec claim(Ecto.Repo.t(), term(), pos_integer(), integer()) :: {:ok, t()} | :taken
  def claim(repo, scene_id, max_beats, beat) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    row = %{
      scene_id: to_string(scene_id),
      status: "running",
      beats_run: 0,
      max_beats: max_beats,
      beat: beat,
      ended_reason: nil,
      inserted_at: now,
      updated_at: now
    }

    {_n, returned} =
      repo.insert_all(
        __MODULE__,
        [row],
        on_conflict:
          from(r in __MODULE__,
            where: r.status != "running",
            update: [
              set: [
                status: "running",
                beats_run: 0,
                max_beats: ^max_beats,
                beat: ^beat,
                ended_reason: nil,
                updated_at: ^now
              ]
            ]
          ),
        conflict_target: :scene_id,
        returning: true
      )

    case returned do
      [run] -> {:ok, run}
      _ -> :taken
    end
  end

  @doc """
  Record that a beat ran. Returns the updated row, or nil if the run is gone.

  An `inc` rather than a read-modify-write: the counter is what the beat cap is checked
  against, and two jobs finishing together must not both read 7 and both write 8.

  Re-read rather than `returning:` — Ecto's `update_all` doesn't populate it here, and a
  silent `nil` from a *successful* update reads as "the run vanished" everywhere
  upstream. The extra select is a primary-key lookup on a one-row table.
  """
  @spec advance(Ecto.Repo.t(), term(), integer()) :: t() | nil
  def advance(repo, scene_id, beat) do
    sid = to_string(scene_id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    repo.update_all(
      from(r in __MODULE__, where: r.scene_id == ^sid and r.status == "running"),
      inc: [beats_run: 1],
      set: [beat: beat, updated_at: now]
    )

    get(repo, sid)
  end

  @doc "Set the run's status, with an optional reason. Returns the updated row or nil."
  @spec set_status(Ecto.Repo.t(), term(), String.t(), String.t() | nil) :: t() | nil
  def set_status(repo, scene_id, status, reason \\ nil) do
    sid = to_string(scene_id)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    repo.update_all(
      from(r in __MODULE__, where: r.scene_id == ^sid),
      set: [status: status, ended_reason: reason, updated_at: now]
    )

    get(repo, sid)
  end
end
