defmodule Polyphony.LLMTelemetryTest do
  @moduledoc """
  The generation path's telemetry — the one measurement this app actually needs.

  A beat fans out to one LLM call per cast member, any of which can be slow, blank,
  refused, or capped, and none of that shows up in a request duration: the work happens
  in an Oban job long after the response went out. `oban.job.*` sees the job;
  this sees the call inside it.

  Asserted by attaching a real handler and making real calls, because a metric
  definition naming an event nobody emits renders as an empty chart — which reads as
  "nothing is happening" rather than "nothing is measured".
  """
  # ConnCase for the Ecto sandbox: the spend-cap branch reads the ledger.
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.LLM

  defmodule OkProvider do
    @moduledoc false
    def complete(_messages, _opts), do: {:ok, "some prose"}
  end

  defmodule ErrorProvider do
    @moduledoc false
    def complete(_messages, _opts), do: {:error, :empty_response}
  end

  defmodule RaisingProvider do
    @moduledoc false
    def complete(_messages, _opts), do: raise("provider exploded")
  end

  setup do
    test = self()
    ref = make_ref()

    events = [
      [:polyphony, :llm, :call, :start],
      [:polyphony, :llm, :call, :stop],
      [:polyphony, :llm, :call, :exception],
      [:polyphony, :llm, :blocked]
    ]

    :telemetry.attach_many(
      "llm-telemetry-test-#{inspect(ref)}",
      events,
      fn name, measurements, metadata, _ ->
        send(test, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("llm-telemetry-test-#{inspect(ref)}") end)
    %{messages: [%{role: "user", content: "hello"}]}
  end

  describe "a completed call" do
    test "emits start and stop with a duration", %{messages: messages} do
      assert {:ok, "some prose"} = LLM.call(messages, provider: OkProvider)

      assert_received {:telemetry, [:polyphony, :llm, :call, :start], _, _}
      assert_received {:telemetry, [:polyphony, :llm, :call, :stop], measurements, metadata}

      assert is_integer(measurements.duration)
      assert metadata.provider == OkProvider
      assert metadata.outcome == :ok
    end

    test "an error result is a stop, not an exception" do
      # It returned; it just returned badly. Conflating the two would make a blank
      # response look like a crash and hide the crashes that matter.
      assert {:error, :empty_response} =
               LLM.call([%{role: "user", content: "x"}], provider: ErrorProvider)

      assert_received {:telemetry, [:polyphony, :llm, :call, :stop], _, metadata}
      assert metadata.outcome == :error
      refute_received {:telemetry, [:polyphony, :llm, :call, :exception], _, _}
    end

    test "carries no prompt or response text", %{messages: messages} do
      # This metadata reaches every attached handler and the dashboard. The fiction is
      # not telemetry — and a prompt is somebody's private scene.
      LLM.call(messages, provider: OkProvider)

      assert_received {:telemetry, [:polyphony, :llm, :call, :stop], _, metadata}

      refute Map.has_key?(metadata, :messages)
      refute inspect(metadata) =~ "hello"
      refute inspect(metadata) =~ "some prose"
    end

    test "the usage kind rides along, so internal calls are separable", %{messages: messages} do
      LLM.call(messages, provider: OkProvider, usage_kind: "embedding")

      assert_received {:telemetry, [:polyphony, :llm, :call, :stop], _, metadata}
      assert metadata.usage_kind == "embedding"
    end
  end

  describe "a raising provider" do
    test "emits an exception event and still raises", %{messages: messages} do
      assert_raise RuntimeError, "provider exploded", fn ->
        LLM.call(messages, provider: RaisingProvider)
      end

      assert_received {:telemetry, [:polyphony, :llm, :call, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.provider == RaisingProvider
      # The span must not swallow it: generation failing loudly is the correct
      # behaviour, and the job retry depends on it.
      assert metadata.kind == :error
    end
  end

  describe "the spend cap" do
    test "a blocked call is its own event, with no duration" do
      # Deliberately not a `:stop` with outcome `:blocked`: nothing was called, so a
      # near-zero duration would drag the latency distribution toward a call that never
      # happened. From outside, a capped campaign looks exactly like generation
      # breaking — this is what tells the two apart.
      #
      # `verdict/4` stops on `spent >= cap`, so a cap of zero blocks with an empty
      # ledger and needs no fixture spend.
      Application.put_env(:polyphony, :costs, daily_cap: 0)
      on_exit(fn -> Application.delete_env(:polyphony, :costs) end)

      # A real id: the ledger's `user_id` is an `:id`, so a made-up string is a cast
      # error rather than a miss.
      user = user_fixture()

      assert {:error, :cost_cap_reached} =
               LLM.call([%{role: "user", content: "x"}],
                 provider: OkProvider,
                 user_id: user.id
               )

      assert_received {:telemetry, [:polyphony, :llm, :blocked], measurements, metadata}
      assert measurements.count == 1
      assert metadata.usage_kind == "generation"

      # The provider was never reached, so there must be no span at all.
      refute_received {:telemetry, [:polyphony, :llm, :call, :start], _, _}
      refute_received {:telemetry, [:polyphony, :llm, :call, :stop], _, _}
    end

    test "an unattributed call is never blocked", %{messages: messages} do
      Application.put_env(:polyphony, :costs, daily_cap: 0)
      on_exit(fn -> Application.delete_env(:polyphony, :costs) end)

      # No user and no campaign means no ledger to cap against — internal calls must
      # not be starved by somebody else's spend.
      assert {:ok, _} = LLM.call(messages, provider: OkProvider)

      assert_received {:telemetry, [:polyphony, :llm, :call, :stop], _, _}
      refute_received {:telemetry, [:polyphony, :llm, :blocked], _, _}
    end
  end
end
