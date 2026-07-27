defmodule Polyphony.DebugLogTest do
  @moduledoc """
  The debug-log ring buffer behind the drawer: it captures log lines via a `:logger`
  handler, hands them back oldest-first, broadcasts new entries + clears to
  subscribers, and clears on demand. `async: false` — it attaches a global logger
  handler for the duration of each test. Logs at `:warning`+ so they clear the test
  logger level (`config/test.exs`).
  """
  use ExUnit.Case, async: false

  require Logger

  alias Polyphony.DebugLog

  setup do
    # start_supervised stops it after the test, which detaches the :logger handler.
    start_supervised!(DebugLog)
    :ok
  end

  @tag :capture_log
  test "captures logged lines oldest-first and clears" do
    Logger.warning("first debug drawer line")
    Logger.warning("second debug drawer line")

    messages = DebugLog.recent() |> Enum.map(& &1.message)
    i1 = Enum.find_index(messages, &(&1 == "first debug drawer line"))
    i2 = Enum.find_index(messages, &(&1 == "second debug drawer line"))

    assert i1 && i2, "both lines captured"
    assert i1 < i2, "returned oldest-first"

    assert :ok = DebugLog.clear()
    assert DebugLog.recent() == []
  end

  @tag :capture_log
  test "each entry carries a level, a time, and a stable id" do
    Logger.error("boom in the drawer")

    entry = DebugLog.recent() |> Enum.find(&(&1.message == "boom in the drawer"))
    assert entry.level == :error
    assert is_binary(entry.id) and entry.id =~ "log-"
    # meta[:time] formats to HH:MM:SS (or "" if unavailable — never crashes).
    assert is_binary(entry.time)
  end

  @tag :capture_log
  test "subscribers receive pushed entries and a clear notice" do
    :ok = DebugLog.subscribe()

    Logger.warning("please broadcast me")
    assert_receive {:debug_log, %{message: "please broadcast me"}}, 1_000

    :ok = DebugLog.clear()
    assert_receive :debug_log_cleared, 1_000
  end
end
