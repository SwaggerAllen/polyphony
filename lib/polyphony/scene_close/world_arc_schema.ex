defmodule Polyphony.SceneClose.WorldArcSchema do
  @moduledoc """
  Structured output for world-arc extraction (§2.8): validate the model's proposed
  world-change entries and convert them to `Polyphony.Authoring.WorldArcEntry`
  structs — **always `:proposed`**. The world counterpart to `ArcSchema`.

  `scope` is the model's call (global vs local); `location_id` is stamped from the
  scene, not the model's job.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Polyphony.Authoring.WorldArcEntry

  @primary_key false
  embedded_schema do
    embeds_many :entries, Entry, primary_key: false do
      field(:kind, Ecto.Enum, values: [:discovery, :revision])
      field(:scope, Ecto.Enum, values: [:global, :local], default: :global)
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
    |> cast(params, [:kind, :scope, :statement])
    |> validate_required([:kind, :statement])
  end

  @doc """
  Parse into `{:ok, [%WorldArcEntry{status: :proposed}]}` tagged with scene +
  location, or `{:error, changeset}`.
  """
  @spec parse(map(), keyword()) :: {:ok, [WorldArcEntry.t()]} | {:error, Ecto.Changeset.t()}
  def parse(data, opts \\ []) do
    cs = changeset(data)

    if cs.valid? do
      entries =
        cs
        |> apply_changes()
        |> Map.get(:entries)
        |> Enum.map(fn e ->
          %WorldArcEntry{
            kind: e.kind,
            scope: e.scope || :global,
            statement: e.statement,
            status: :proposed,
            beat: Keyword.get(opts, :beat),
            source_scene_id: Keyword.get(opts, :source_scene_id),
            # A local fact is local to where the scene happened; global carries no place.
            location_id: if(e.scope == :local, do: Keyword.get(opts, :location_id))
          }
        end)

      {:ok, entries}
    else
      {:error, cs}
    end
  end
end
