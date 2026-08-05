defmodule Polyphony.ReadModels.BuildRun do
  @moduledoc """
  One row per campaign that has had a Quick Build run on it — the build's progress,
  outcome, and the sentence to show for it.

  Workflow state, not fiction: like `PacketDraft` and `Failures` it is deliberately
  **off** the event log, so `Visibility` can never see it and a replay never re-runs a
  build. The unique index on `campaign_id` is the concurrency control rather than a
  tidiness constraint — see the migration.
  """
  use Ecto.Schema

  import Ecto.Query

  @type t :: %__MODULE__{}

  schema "build_runs" do
    field(:campaign_id, :string)
    field(:status, :string, default: "running")
    field(:step, :integer, default: 0)
    field(:total, :integer, default: 1)
    field(:label, :string)
    field(:detail, :string)
    # The seed indexes already written, and the arguments the build was started with —
    # see the migration. Both exist so a retry resumes rather than restarts.
    field(:done, {:array, :integer}, default: [])
    field(:request, :binary)
    timestamps(type: :naive_datetime_usec)
  end

  @spec get(Ecto.Repo.t(), term()) :: t() | nil
  def get(repo, campaign_id) do
    cid = to_string(campaign_id)
    repo.one(from(r in __MODULE__, where: r.campaign_id == ^cid))
  end

  @doc """
  Claim the campaign for a new run, or `:taken` if one is already under way.

  An upsert rather than a get-then-insert: two taps that race arrive at the database
  together, and only the one whose `ON CONFLICT` clause matched a non-running row
  comes back with a claim.
  """
  @spec claim(Ecto.Repo.t(), term(), pos_integer(), binary() | nil) :: {:ok, t()} | :taken
  def claim(repo, campaign_id, total, request \\ nil) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    row = %{
      campaign_id: to_string(campaign_id),
      status: "running",
      step: 0,
      total: total,
      label: "Starting",
      detail: nil,
      done: [],
      request: request,
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
                step: 0,
                total: ^total,
                label: "Starting",
                detail: nil,
                done: [],
                request: ^request,
                updated_at: ^now
              ]
            ]
          ),
        conflict_target: :campaign_id,
        returning: true
      )

    case returned do
      [%__MODULE__{} = claimed] -> {:ok, claimed}
      [] -> :taken
    end
  end

  @spec update(Ecto.Repo.t(), term(), map()) :: t() | nil
  def update(repo, campaign_id, changes) do
    cid = to_string(campaign_id)
    changes = Map.put(changes, :updated_at, NaiveDateTime.utc_now())

    {_n, returned} =
      repo.update_all(
        from(r in __MODULE__, where: r.campaign_id == ^cid, select: r),
        set: Map.to_list(changes)
      )

    List.first(returned)
  end

  @doc """
  Record that a seed's character has been written.

  Appended in the database rather than read-modify-written in the job, so the record
  survives the crash it exists to survive.
  """
  @spec mark_done(Ecto.Repo.t(), term(), non_neg_integer()) :: :ok
  def mark_done(repo, campaign_id, index) do
    cid = to_string(campaign_id)

    repo.update_all(
      from(r in __MODULE__, where: r.campaign_id == ^cid),
      push: [done: index]
    )

    :ok
  end

  @spec delete(Ecto.Repo.t(), term()) :: :ok
  def delete(repo, campaign_id) do
    cid = to_string(campaign_id)
    repo.delete_all(from(r in __MODULE__, where: r.campaign_id == ^cid))
    :ok
  end
end
