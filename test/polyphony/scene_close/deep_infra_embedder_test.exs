defmodule Polyphony.SceneClose.DeepInfraEmbedderTest do
  @moduledoc """
  The DeepInfra embedder's response handling (§8). The network path uses `:httpc`
  and isn't exercised offline (like the chat adapter); the OpenAI-compatible
  response shape is parsed by a pure function, tested here.
  """
  use ExUnit.Case, async: true

  alias Polyphony.SceneClose.DeepInfraEmbedder

  test "extracts the embedding vector from the OpenAI-compatible response" do
    resp = %{
      "data" => [%{"embedding" => [0.1, -0.2, 0.3], "index" => 0}],
      "model" => "BAAI/bge-large-en-v1.5"
    }

    assert {:ok, [0.1, -0.2, 0.3]} = DeepInfraEmbedder.extract_embedding(resp)
  end

  test "an empty or malformed response is an error, not a crash" do
    assert {:error, {:unexpected_response, _}} =
             DeepInfraEmbedder.extract_embedding(%{"data" => []})

    assert {:error, {:unexpected_response, _}} =
             DeepInfraEmbedder.extract_embedding(%{"error" => "bad model"})
  end

  test "the module is a valid Embedder implementation" do
    behaviours =
      DeepInfraEmbedder.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Polyphony.SceneClose.Embedder in behaviours
  end
end
