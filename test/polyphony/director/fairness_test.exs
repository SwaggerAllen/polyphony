defmodule Polyphony.Director.FairnessTest do
  @moduledoc "The casting fairness heuristic (§10) — pure projection over the log."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias PolyphonyCore.Director.Fairness

  defp log do
    [
      speech("mira", "S1", 1, "a"),
      speech("mira", "S1", 2, "b"),
      speech("otto", "S1", 2, "c"),
      speech("mira", "S2", 1, "elsewhere"),
      thought("otto", "S1", 3, "not speech")
    ]
  end

  test "counts speech per speaker, scoped to the scene" do
    counts = Fairness.speak_counts(log(), "S1")
    assert counts == %{"mira" => 2, "otto" => 1}
  end

  test "can limit to recent beats" do
    counts = Fairness.speak_counts(log(), "S1", since_beat: 2)
    assert counts == %{"mira" => 1, "otto" => 1}
  end

  test "orders least-spoken-first as a casting suggestion" do
    counts = Fairness.speak_counts(log(), "S1")
    assert Fairness.least_spoken_first(["mira", "otto"], counts) == ["otto", "mira"]
  end

  test "a character who hasn't spoken sorts first" do
    counts = Fairness.speak_counts(log(), "S1")
    assert Fairness.least_spoken_first(["mira", "silent"], counts) == ["silent", "mira"]
  end
end
