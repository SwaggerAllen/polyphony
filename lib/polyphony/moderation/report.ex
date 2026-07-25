defmodule Polyphony.Moderation.Report do
  @moduledoc """
  A report on public/unlisted content (§B3). The reporter is always authenticated
  (a FK), the reported item is identified by `item_type` + `item_id`, and `owner_id`
  is denormalized so resolving the report can grant scoped, audited access to the
  owning account (§C reactive access).

  Reason categories **lead with the absolute lines** — CSAM and real-person sexual
  content — because those drive the harshest, account-level response; `absolute_line?/1`
  marks them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Ordered: the two absolute lines first, then the rest.
  @reasons ~w(csam real_person_sexual other_illegal harassment nonconsensual_content other)a
  @absolute_lines ~w(csam real_person_sexual)a
  @statuses ~w(open actioned dismissed)

  schema "reports" do
    field(:reporter_id, :id)
    field(:owner_id, :id)
    field(:item_type, :string)
    field(:item_id, :integer)
    field(:reason, :string)
    field(:detail, :string)
    field(:status, :string, default: "open")
    field(:resolution, :string)
    field(:resolution_reason, :string)
    field(:resolved_by_id, :id)
    field(:resolved_at, :naive_datetime_usec)
    timestamps(type: :naive_datetime_usec)
  end

  @doc "The report reason categories, absolute lines first."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc "Is `reason` an absolute line (CSAM / real-person sexual content)?"
  @spec absolute_line?(atom() | String.t()) :: boolean()
  def absolute_line?(reason), do: to_atom(reason) in @absolute_lines

  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:reporter_id, :owner_id, :item_type, :item_id, :reason, :detail])
    |> validate_required([:reporter_id, :item_type, :reason])
    |> validate_inclusion(:reason, Enum.map(@reasons, &to_string/1))
    |> put_change(:status, "open")
  end

  def resolve_changeset(%__MODULE__{} = report, attrs) do
    report
    |> cast(attrs, [:status, :resolution, :resolution_reason, :resolved_by_id, :resolved_at])
    |> validate_inclusion(:status, @statuses)
  end

  defp to_atom(r) when is_atom(r), do: r
  defp to_atom(r) when is_binary(r), do: Enum.find(@reasons, &(to_string(&1) == r))
end
