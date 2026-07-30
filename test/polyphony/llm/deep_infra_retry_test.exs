defmodule Polyphony.LLM.DeepInfraRetryTest do
  @moduledoc "Transient-error retry with backoff (§3) — 429/overload + timeouts."
  use ExUnit.Case, async: true

  alias Polyphony.LLM.DeepInfra

  # No real sleeping in tests.
  @cfg [max_retries: 3, retry_base_ms: 0]

  defp counter(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)

    fn ->
      Agent.get_and_update(agent, fn
        [head | tail] -> {head, tail}
        [] -> {{:ok, "exhausted"}, []}
      end)
    end
  end

  test "classifies 429, 5xx and transport errors as transient; 4xx as not" do
    assert DeepInfra.transient?({:http_status, 429, "busy"})
    assert DeepInfra.transient?({:http_status, 503, "down"})
    assert DeepInfra.transient?({:transport, :timeout})
    refute DeepInfra.transient?({:http_status, 400, "bad"})
    refute DeepInfra.transient?({:http_status, 404, "gone"})
  end

  test "retries a transient failure then succeeds" do
    fun = counter([{:error, {:http_status, 429, "busy"}}, {:ok, "ok now"}])
    assert DeepInfra.with_retry(@cfg, fun) == {:ok, "ok now"}
  end

  test "gives up after max_retries on a persistent transient failure" do
    fun = counter(List.duplicate({:error, {:transport, :timeout}}, 10))
    assert DeepInfra.with_retry(@cfg, fun) == {:error, {:transport, :timeout}}
  end

  test "does not retry a non-transient (real) request error" do
    fun = counter([{:error, {:http_status, 400, "bad request"}}, {:ok, "should not reach"}])
    assert DeepInfra.with_retry(@cfg, fun) == {:error, {:http_status, 400, "bad request"}}
  end
end
