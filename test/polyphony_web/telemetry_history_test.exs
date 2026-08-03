defmodule PolyphonyWeb.TelemetryHistoryTest do
  @moduledoc """
  The ten-minute backlog behind LiveDashboard's Metrics tab.

  Without it the dashboard draws only what happens while the tab is open, so opening
  it *after* something went wrong shows nothing about it — which is the one moment it
  is wanted. The window is short on purpose: "what just happened" is the question a
  bring-up dashboard answers, and anything longer is a time-series database in
  disguise.
  """
  use ExUnit.Case, async: false

  alias PolyphonyWeb.Telemetry.History

  setup do
    # The app already supervises it, so this works against the running instance and
    # just empties the table — one test's datapoints must not become another's
    # history, and the whole suite is emitting Ecto and Phoenix events into it.
    :ets.delete_all_objects(History)
    on_exit(fn -> :ets.delete_all_objects(History) end)
    :ok
  end

  defp llm_metric do
    Enum.find(PolyphonyWeb.Telemetry.metrics(), fn m ->
      m.event_name == [:polyphony, :llm, :call, :stop] and
        match?(%Telemetry.Metrics.Distribution{}, m)
    end)
  end

  describe "recording" do
    test "an emitted event turns up in the metric's history" do
      :telemetry.execute(
        [:polyphony, :llm, :call, :stop],
        %{duration: System.convert_time_unit(1_500, :millisecond, :native)},
        %{provider: FakeProvider, outcome: :ok}
      )

      assert [point] = History.metrics_history(llm_metric())

      # The shape the Metrics page destructures. Getting this wrong is a crash on
      # page load, not a missing chart.
      assert %{label: _, measurement: measurement, time: time} = point
      assert_in_delta measurement, 1_500, 1
      assert is_integer(time)
    end

    test "the label carries the metric's tags, so history lands on the right series" do
      :telemetry.execute(
        [:polyphony, :llm, :call, :stop],
        %{duration: 1},
        %{provider: FakeProvider, outcome: :ok}
      )

      assert [%{label: label}] = History.metrics_history(llm_metric())
      # The distribution is tagged by provider only.
      assert label =~ "FakeProvider"
    end

    test "two metrics over the same event keep separate backlogs" do
      # A distribution and a counter both read `polyphony.llm.call.stop.duration`.
      # Keyed by name alone they would pool, and the counter's series would inherit
      # the distribution's points.
      counter =
        Enum.find(PolyphonyWeb.Telemetry.metrics(), fn m ->
          m.event_name == [:polyphony, :llm, :call, :stop] and
            match?(%Telemetry.Metrics.Counter{}, m)
        end)

      :telemetry.execute(
        [:polyphony, :llm, :call, :stop],
        %{duration: 42},
        %{provider: FakeProvider, outcome: :ok}
      )

      [dist_point] = History.metrics_history(llm_metric())
      [counter_point] = History.metrics_history(counter)

      # Same event, different series: the counter is tagged provider *and* outcome.
      assert dist_point.label != counter_point.label
    end

    test "an event nothing is watching for is simply not recorded" do
      :telemetry.execute([:polyphony, :nothing, :listens], %{duration: 1}, %{})

      assert History.metrics_history(llm_metric()) == []
    end

    test "ordered oldest first" do
      for n <- 1..3 do
        :telemetry.execute(
          [:polyphony, :llm, :call, :stop],
          %{duration: n},
          %{provider: FakeProvider, outcome: :ok}
        )
      end

      times = History.metrics_history(llm_metric()) |> Enum.map(& &1.time)
      assert times == Enum.sort(times)
    end
  end

  describe "robustness" do
    test "reading always answers a list, never raises" do
      # The dashboard calls this on mount, so a raise here is a 500 on the admin page
      # rather than a missing chart. The table can legitimately be absent — during a
      # restart, or before the supervisor has come up — which is why the read rescues.
      assert History.metrics_history(llm_metric()) == []

      :telemetry.execute([:polyphony, :llm, :call, :stop], %{duration: 1}, %{
        provider: FakeProvider,
        outcome: :ok
      })

      assert [_] = History.metrics_history(llm_metric())
    end

    test "a handler crash never propagates into the measured code" do
      # The handler runs in the *emitting* process — inside a beat, inside a query.
      # Nothing it does may reach back into that.
      assert :ok =
               History.handle_event([:polyphony, :llm, :call, :stop], %{duration: 1}, %{}, [
                 %{not: "a metric"}
               ])
    end
  end

  describe "the borrowed extraction" do
    test "LiveDashboard's datapoint extractor is still there, and still that shape" do
      # `Phoenix.LiveDashboard.TelemetryListener` is `@moduledoc false` — private API.
      # We use it so history and live points land on identical series rather than a
      # reimplementation drifting from it. If an upgrade moves it, this fails loudly
      # instead of the charts quietly going empty.
      Code.ensure_loaded!(Phoenix.LiveDashboard.TelemetryListener)

      assert function_exported?(
               Phoenix.LiveDashboard.TelemetryListener,
               :extract_datapoint_for_metric,
               4
             )

      point =
        Phoenix.LiveDashboard.TelemetryListener.extract_datapoint_for_metric(
          llm_metric(),
          %{duration: 5},
          %{provider: FakeProvider, outcome: :ok},
          123
        )

      assert %{label: _, measurement: _, time: 123} = point
    end
  end
end
