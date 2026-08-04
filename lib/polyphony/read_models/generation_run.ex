defmodule Polyphony.ReadModels.GenerationRun do
  @moduledoc """
  One authoring generation: what was asked, and what came back.

  Workflow state, off the event log, like `PacketDraft` and `Failures` — a half-written
  paragraph is not a fact about the fiction, and `Visibility` must never be able to see
  one. `Polyphony.Generations` owns the codec and the meaning; this is the table.
  """
  use Ecto.Schema

  import Ecto.Query

  @type t :: %__MODULE__{}

  schema "generation_runs" do
    field(:subject, :string)
    field(:key, :string)
    field(:op, :string)
    field(:request, :binary)
    field(:status, :string, default: "running")
    field(:result, :binary)
    timestamps(type: :naive_datetime_usec)
  end

  @doc """
  Claim (subject, key) for a run, replacing whatever was there.

  Replacing rather than refusing: pressing ✦ twice means you want the second answer, and
  the first is now worth nothing.

  **Delete-then-insert, not an upsert**, and the difference is the whole point. An
  upsert reuses the row id, so the superseded job would come back, find its id still
  there, and write its stale answer over the one the author actually waited for. A new
  row means the old id is gone, `update/3` returns nil, and `Generations.finish/2` drops
  it. One transaction, because a claim with no row is a spinner that never stops.

  Two tabs claiming the same control in the same instant is the one case this doesn't
  serialise; the unique index turns it into an error the screen's `safe/2` reports,
  which is the right outcome for "two of you pressed the same button".
  """
  @spec claim(Ecto.Repo.t(), map()) :: t()
  def claim(repo, attrs) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    subject = attrs.subject
    key = attrs.key

    {:ok, row} =
      repo.transaction(fn ->
        repo.delete_all(from(r in __MODULE__, where: r.subject == ^subject and r.key == ^key))

        repo.insert!(
          struct(__MODULE__, Map.merge(attrs, %{status: "running", result: nil}))
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        )
      end)

    row
  end

  @spec get(Ecto.Repo.t(), term()) :: t() | nil
  def get(repo, id), do: repo.get(__MODULE__, id)

  @spec update(Ecto.Repo.t(), term(), map()) :: t() | nil
  def update(repo, id, changes) do
    changes = Map.put(changes, :updated_at, NaiveDateTime.utc_now())

    {_n, returned} =
      repo.update_all(from(r in __MODULE__, where: r.id == ^id, select: r),
        set: Map.to_list(changes)
      )

    List.first(returned)
  end

  @doc "Every run for a subject, whatever its state."
  @spec list(Ecto.Repo.t(), term()) :: [t()]
  def list(repo, subject) do
    s = to_string(subject)
    repo.all(from(r in __MODULE__, where: r.subject == ^s, order_by: [asc: r.inserted_at]))
  end

  @doc "Take the finished runs for a subject and forget them — read exactly once."
  @spec take_finished(Ecto.Repo.t(), term()) :: [t()]
  def take_finished(repo, subject) do
    s = to_string(subject)

    {_n, taken} =
      repo.delete_all(
        from(r in __MODULE__, where: r.subject == ^s and r.status != "running", select: r)
      )

    Enum.sort_by(taken || [], & &1.inserted_at, NaiveDateTime)
  end

  @spec delete(Ecto.Repo.t(), term(), String.t()) :: :ok
  def delete(repo, subject, key) do
    s = to_string(subject)
    repo.delete_all(from(r in __MODULE__, where: r.subject == ^s and r.key == ^key))
    :ok
  end
end
