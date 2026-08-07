defmodule Polyphony.Projectors.SceneForks do
  @moduledoc """
  Projects `SceneForked` into the `scene_forks` lineage read model (§7) — a thin
  Commanded wrapper over `Polyphony.ReadModels.SceneFork`, matching the membership
  projector's shape.
  """
  use Commanded.Projections.Ecto,
    application: Polyphony.App,
    repo: Polyphony.Repo,
    name: "scene_forks"

  alias PolyphonyCore.Events.SceneForked
  alias Polyphony.ReadModels.SceneFork

  project(%SceneForked{} = e, _metadata, fn multi ->
    Ecto.Multi.run(multi, :fork, fn repo, _ ->
      {:ok,
       SceneFork.put(repo, %{
         scene_id: e.scene_id,
         parent_scene_id: e.parent_scene_id,
         fork_beat: e.fork_beat,
         label: e.label,
         campaign_id: e.campaign_id
       })}
    end)
  end)
end
