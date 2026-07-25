defmodule Polyphony.Authoring.FieldStore do
  @moduledoc """
  The authoring metadata store (§15) — one row per `(subject_id, field)` holding
  the field's `value` plus its **workflow metadata**: `status`
  (`draft | accepted | locked`), accumulated `feedback`, and provenance
  (`model`, `prompt_hash`).

  This is intentionally *not* the generation schema. Keeping status/feedback/lock
  out of the struct the model sees is what stops the model trying to generate
  them; the studio builds a single-field generation schema instead.
  """
  use Ecto.Schema
  import Ecto.Query

  @statuses ~w(draft accepted locked)

  schema "authoring_fields" do
    field(:subject_id, :string)
    field(:subject_type, :string, default: "character")
    field(:field, :string)
    field(:value, :string)
    field(:status, :string, default: "draft")
    field(:feedback, {:array, :string}, default: [])
    field(:model, :string)
    field(:prompt_hash, :string)
    timestamps(type: :naive_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "Upsert a field's value + provenance, resetting it to :draft."
  def put(repo, subject_id, field, value, opts \\ []) do
    sid = to_string(subject_id)
    fld = to_string(field)

    repo.insert!(
      %__MODULE__{
        subject_id: sid,
        field: fld,
        value: value,
        status: "draft",
        feedback: Keyword.get(opts, :feedback, []),
        model: Keyword.get(opts, :model),
        prompt_hash: Keyword.get(opts, :prompt_hash)
      },
      on_conflict: {:replace, [:value, :status, :model, :prompt_hash, :updated_at]},
      conflict_target: [:subject_id, :field]
    )
  end

  def get(repo, subject_id, field) do
    repo.get_by(__MODULE__, subject_id: to_string(subject_id), field: to_string(field))
  end

  def list(repo, subject_id) do
    sid = to_string(subject_id)
    repo.all(from(f in __MODULE__, where: f.subject_id == ^sid, order_by: f.field))
  end

  @doc "Set a field's review status (draft → accepted → locked)."
  def set_status(repo, subject_id, field, status) when status in @statuses do
    case get(repo, subject_id, field) do
      nil -> {:error, :not_found}
      row -> {:ok, row |> Ecto.Changeset.change(status: status) |> repo.update!()}
    end
  end

  @doc "Append a piece of feedback to a field (accumulates for the next regen)."
  def add_feedback(repo, subject_id, field, text) do
    case get(repo, subject_id, field) do
      nil ->
        {:error, :not_found}

      row ->
        {:ok, row |> Ecto.Changeset.change(feedback: row.feedback ++ [text]) |> repo.update!()}
    end
  end
end
