defmodule Polyphony.Repo.Migrations.WidenSummaryEmbedding do
  use Ecto.Migration

  # The `embedding` column was sized 8 to match the deterministic `MockEmbedder`.
  # Real embeddings (BAAI/bge-large-en-v1.5) are 1024-dim. Only throwaway test data
  # existed, and vector(8) can't cast to vector(1024), so drop and re-add rather
  # than convert. Dev/test's MockEmbedder is bumped to 1024 in lockstep.
  def up do
    alter table(:character_scene_summaries) do
      remove :embedding
      add :embedding, :vector, size: 1024
    end
  end

  def down do
    alter table(:character_scene_summaries) do
      remove :embedding
      add :embedding, :vector, size: 8
    end
  end
end
