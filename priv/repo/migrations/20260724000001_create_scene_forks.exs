defmodule Polyphony.Repo.Migrations.CreateSceneForks do
  use Ecto.Migration

  def change do
    create table(:scene_forks) do
      add(:scene_id, :string, null: false)
      add(:parent_scene_id, :string, null: false)
      add(:fork_beat, :integer)
      add(:label, :string)
      add(:campaign_id, :string)
      timestamps(type: :naive_datetime_usec)
    end

    create(unique_index(:scene_forks, [:scene_id]))
    create(index(:scene_forks, [:parent_scene_id]))
    create(index(:scene_forks, [:campaign_id]))
  end
end
