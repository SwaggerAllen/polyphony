defmodule Polyphony.SceneClose.ArcSchema do
  @moduledoc """
  Structured output for arc extraction (§6.2): validate the model's proposed arc
  entries and convert them to `Polyphony.Authoring.ArcEntry` structs — **always
  `:proposed`**, never straight to canon. Models over-assert significance; the
  veto is the point.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Polyphony.Authoring.ArcEntry

  @primary_key false
  embedded_schema do
    embeds_many :entries, Entry, primary_key: false do
      field(:kind, Ecto.Enum, values: [:discovery, :revision])
      field(:sheet_field, :string)
      field(:statement, :string)
    end
  end

  def changeset(data) when is_map(data) do
    %__MODULE__{}
    |> cast(data, [])
    |> cast_embed(:entries, with: &entry_changeset/2)
  end

  defp entry_changeset(entry, params) do
    entry
    |> cast(params, [:kind, :sheet_field, :statement])
    |> validate_required([:kind, :statement])
  end

  @doc """
  Parse into `{:ok, [%ArcEntry{status: :proposed}]}` tagged with subject/scene,
  or `{:error, changeset}`.
  """
  @spec parse(map(), keyword()) :: {:ok, [ArcEntry.t()]} | {:error, Ecto.Changeset.t()}
  def parse(data, opts \\ []) do
    cs = changeset(data)

    if cs.valid? do
      entries =
        cs
        |> apply_changes()
        |> Map.get(:entries)
        |> Enum.map(fn e ->
          %ArcEntry{
            kind: e.kind,
            sheet_field: e.sheet_field,
            statement: e.statement,
            status: :proposed,
            beat: Keyword.get(opts, :beat),
            source_scene_id: Keyword.get(opts, :source_scene_id)
          }
        end)

      {:ok, entries}
    else
      {:error, cs}
    end
  end
end
