defmodule Polyphony.Repo.Migrations.CreateSceneAutoRuns do
  @moduledoc """
  A scene left to run itself.

  Continue advances one beat and hands back. That is the right default for playing,
  and useless for the thing that needs a *finished* scene to look at — arc review,
  which has nothing to review until a scene has run long enough to change somebody.
  Getting there meant tapping Continue thirty times.

  An auto run is the loop without the hand-back, bounded three ways: the Director
  closing the scene, the room emptying, and a hard beat cap. It is a row rather than
  job args because it has to be **pausable**, and a pause is a fact about the scene
  that outlives whichever job is in flight — and because "is this scene running itself,
  and how far in" is a question the play screen asks on mount, after a reload, or from
  a second device.

  One row per scene. The uniqueness is the concurrency control: a second tap on Auto
  can't start a second loop into the same transcript.
  """
  use Ecto.Migration

  def change do
    create table(:scene_auto_runs) do
      add(:scene_id, :string, null: false)
      # running | paused | done
      add(:status, :string, null: false, default: "running")
      add(:beats_run, :integer, null: false, default: 0)
      add(:max_beats, :integer, null: false, default: 50)
      add(:beat, :integer)
      # The sentence the screen shows when it is over: which of the three stops it was.
      add(:ended_reason, :string)
      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:scene_auto_runs, [:scene_id]))
  end
end
