defmodule Polyphony.EmbeddingsTest do
  @moduledoc """
  The metered embedding boundary (§B5): every embed books estimated usage into the
  ledger when attributed, records nothing when unattributed or on error, and never
  lets a ledger failure break the embed.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Embeddings, Costs, Repo}
  alias Polyphony.Costs.Ledger
  alias Polyphony.SceneClose.MockEmbedder

  defmodule FailEmbedder do
    @behaviour Polyphony.SceneClose.Embedder
    @impl true
    def embed(_text), do: {:error, :boom}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "records estimated usage for an attributed embed" do
    assert {:ok, _vec} =
             Embeddings.embed("summarize this scene",
               embedder: MockEmbedder,
               user_id: 42,
               campaign_id: "c1"
             )

    assert Costs.spent_today(42) > 0
    assert [%Ledger{kind: "embedding", user_id: 42, campaign_id: "c1"}] = Repo.all(Ledger)
  end

  test "writes nothing when the embed is unattributed" do
    assert {:ok, _} = Embeddings.embed("x", embedder: MockEmbedder)
    assert Repo.aggregate(Ledger, :count) == 0
  end

  test "writes nothing when the embedder errors" do
    assert {:error, :boom} = Embeddings.embed("x", embedder: FailEmbedder, user_id: 7)
    assert Costs.spent_today(7) == 0
  end

  test "estimate grows with input size" do
    assert Embeddings.estimate(String.duplicate("word ", 500)) > Embeddings.estimate("hi")
  end
end
