defmodule Polyphony.GenerationTest do
  @moduledoc """
  The generation orchestration (§15 slice 3, §12 failure classification) with an
  injected stub provider — no network. Each test controls the provider via
  `respond_with`, so they stay async and deterministic.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Generation
  alias Polyphony.LLM.Stub
  alias Polyphony.TurnPacket

  @messages [%{role: "user", content: "your turn"}]

  defp generate(respond_with),
    do: Generation.generate(@messages, provider: Stub, respond_with: respond_with)

  test "valid JSON becomes a TurnPacket" do
    assert {:ok, %TurnPacket{moves: [_ | _]}} = generate({:ok, Stub.canned_packet_json()})
  end

  test "a refusal is classified distinctly (§12) and not retried in-band" do
    assert {:error, {:refusal, text}} = generate({:ok, Stub.refusal_text()})
    assert text =~ "can't help"
  end

  test "an empty response surfaces as a transient error" do
    assert {:error, {:empty_response, _}} = generate({:error, :empty_response})
  end

  test "a transport error is tagged for Oban backoff" do
    assert {:error, {:provider, {:transport, :timeout}}} =
             generate({:error, {:transport, :timeout}})
  end

  test "invalid JSON exhausts corrective retries then fails as schema_invalid" do
    assert {:error, {:schema_invalid, _}} = generate({:ok, "not json at all"})
  end

  test "schema-invalid content fails after retries" do
    bad = Jason.encode!(%{moves: []})
    assert {:error, {:schema_invalid, msg}} = generate({:ok, bad})
    assert is_binary(msg)
  end

  test "a corrective retry can recover: first call bad JSON, second call valid" do
    # The stub responds by counting turns via the message list length: the
    # corrective retry appends two messages, so we can key off that.
    responder = fn messages ->
      if length(messages) > 1 do
        {:ok, Stub.canned_packet_json()}
      else
        {:ok, "oops not json"}
      end
    end

    assert {:ok, %TurnPacket{}} =
             Generation.generate(@messages, provider: Stub, respond_with: responder)
  end

  test "refusal detection ignores refusal-like words deep in normal prose" do
    # Only the head of the response is checked, so a story mentioning the phrase
    # later is not a refusal.
    packet =
      Jason.encode!(%{
        moves: [%{seq: 1, type: "speech", content: "I cannot help but wonder if you're lying."}]
      })

    assert {:ok, %TurnPacket{}} = generate({:ok, packet})
  end
end
