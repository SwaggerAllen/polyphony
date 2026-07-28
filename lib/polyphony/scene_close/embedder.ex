defmodule Polyphony.SceneClose.Embedder do
  @moduledoc """
  The embedding boundary (§8). A summary is embedded once at scene close and
  retrieved later via pgvector. Behind a behaviour so the pipeline and its tests
  don't depend on a live embedding model.

  Production calls an embedding endpoint via `Polyphony.SceneClose.DeepInfraEmbedder`
  (selected by config in prod); dev/test stay on the offline `MockEmbedder`. The
  vector dimension is fixed by the `character_scene_summaries` column (1024, matching
  BAAI/bge-large-en-v1.5), so switching to a different-dimension model is a migration.
  """
  @callback embed(String.t()) :: {:ok, [float()]} | {:error, term()}

  @doc "The configured embedder (defaults to the deterministic mock)."
  def default do
    Application.get_env(:polyphony, :embedder, Polyphony.SceneClose.MockEmbedder)
  end
end

defmodule Polyphony.SceneClose.MockEmbedder do
  @moduledoc """
  A network-free embedder producing a deterministic vector from the text — good
  enough to exercise storage and character-scoped retrieval. No `Math.random`
  (replay-hostile); the vector is a fixed function of the content's hash. Its
  dimension matches the real embedder's (and the column's) so dev/test vectors are
  storable and switching to the live embedder needs no schema change.
  """
  @behaviour Polyphony.SceneClose.Embedder

  @dim 1024

  @impl true
  def embed(text) when is_binary(text) do
    seed = :erlang.phash2(text)
    {:ok, for(i <- 1..@dim, do: :math.sin(seed * 0.001 * i))}
  end

  @doc "The embedding dimension (matches the migration's vector size)."
  def dim, do: @dim
end
