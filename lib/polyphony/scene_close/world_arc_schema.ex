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

  alias Polyphony.Authoring.{Audience, WorldArcEntry}

  @primary_key false
  embedded_schema do
    embeds_many :entries, Entry, primary_key: false do
      field(:kind, Ecto.Enum, values: [:discovery, :revision])
      field(:scope, Ecto.Enum, values: [:global, :local], default: :global)
      field(:statement, :string)
      field(:reason, :string)
      # Who comes to know it. "everyone" is common knowledge — the default, and what
      # fixes the off-screen problem: the fact is delivered and they react on the page.
      # "scene" is whoever was there, which arc can express because it has a source
      # scene. The author can change it in review either way.
      field(:known_by, Ecto.Enum, values: [:everyone, :scene], default: :everyone)
    end
  end

  def changeset(data) when is_map(data) do
    %__MODULE__{}
    |> cast(data, [])
    |> cast_embed(:entries, with: &entry_changeset/2)
  end

  defp entry_changeset(entry, params) do
    entry
    |> cast(params, [:kind, :scope, :statement, :reason, :known_by])
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
            reason: e.reason,
            # Everyone → plain canon. Whoever was there → concealed with a scene
            # audience, which `EffectiveWorldBible` folds in as a secret only that
            # scene's cast starts out holding.
            concealed: e.known_by == :scene,
            audience: if(e.known_by == :scene, do: %Audience{scene: true}),
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
