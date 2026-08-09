defmodule Polyphony.ReadModels.Failure do
  @moduledoc """
  The user-facing failure log (§12): a terminal generation failure the user can
  see and act on. Stores the `worker` + `args` needed to **re-enqueue the exact
  work**, plus classification (`kind`, `editable`, `retryable`).
  """
  use Ecto.Schema
  import Ecto.Query

  @typedoc "A row of this table. `Ecto.Schema` generates no `t/0`, so it is declared here."
  @type t :: %__MODULE__{}

  schema "generation_failures" do
    field(:scene_id, :string)
    field(:beat, :integer)
    field(:subject, :string)
    field(:operation, :string)
    field(:kind, :string)
    field(:reason, :string)
    field(:editable, :boolean, default: false)
    field(:retryable, :boolean, default: true)
    field(:status, :string, default: "open")
    field(:worker, :string)
    field(:args, :map, default: %{})
    timestamps(type: :naive_datetime_usec)
  end

  @doc "Insert a failure row from a plain attribute map."
  def put(repo, attrs) do
    repo.insert!(struct(__MODULE__, Map.put(attrs, :status, "open")))
  end

  def get(repo, id), do: repo.get(__MODULE__, id)

  @doc "Open (unresolved) failures for a scene, newest first."
  def list_open(repo, scene_id) do
    sid = to_string(scene_id)

    repo.all(
      from(f in __MODULE__,
        where: f.scene_id == ^sid and f.status == "open",
        order_by: [desc: f.inserted_at]
      )
    )
  end

  @doc """
  Open **turn** failures for one character in a scene, newest first — the ones a
  viewer who can act for that character may see (§1.7). Restricted to `packet`
  operations; author-facing failures (summaries, arc extraction) never scope to a
  character.
  """
  def list_open_for_subject(repo, scene_id, subject) do
    sid = to_string(scene_id)
    who = to_string(subject)

    repo.all(
      from(f in __MODULE__,
        where:
          f.scene_id == ^sid and f.status == "open" and
            f.operation == "packet" and f.subject == ^who,
        order_by: [desc: f.inserted_at]
      )
    )
  end

  def resolve(repo, id) do
    case get(repo, id) do
      nil -> :error
      row -> {:ok, row |> Ecto.Changeset.change(status: "resolved") |> repo.update!()}
    end
  end
end
