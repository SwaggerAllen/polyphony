defmodule Polyphony.Repo.Migrations.CreateSceneMemberships do
  use Ecto.Migration

  # The membership interval read model (§8). A pure projection over
  # CharacterEntered/Exited — rebuildable from the log — but materialized so
  # `member_at?/3` is an index scan instead of an O(n) fold on every query.
  #
  # Re-entry is a second row; there is no special casing. `exited_beat IS NULL`
  # means still present.
  def change do
    create table(:scene_memberships) do
      add :scene_id, :string, null: false
      add :character_id, :string, null: false
      add :entered_beat, :integer, null: false
      add :exited_beat, :integer
    end

    # The hot path: "is (scene, character) present at beat?" — narrow the scan to
    # the (scene, character) intervals, then range-check the beat.
    create index(:scene_memberships, [:scene_id, :character_id])

    # "who is at this scene at beat?" (Director's "who could walk in") is served
    # by the same table scoped to scene.
    create index(:scene_memberships, [:scene_id])
  end
end
