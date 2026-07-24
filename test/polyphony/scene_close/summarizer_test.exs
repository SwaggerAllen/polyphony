defmodule Polyphony.SceneClose.SummarizerTest do
  @moduledoc "Per-character summaries are built from the filtered view (§8 fix #1)."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias Polyphony.SceneClose.Summarizer
  alias Polyphony.LLM.Stub

  defp log do
    [
      entered("S1", "mira", 1),
      entered("S1", "otto", 1),
      thought("mira", "S1", 2, "POISON-IN-THE-WINE"),
      speech("mira", "S1", 2, "More wine?")
    ]
  end

  # A spy provider that captures the transcript it was asked to summarize.
  defp capture(viewer) do
    spy = fn messages ->
      send(self(), {:captured, messages})
      {:ok, "a summary"}
    end

    {:ok, "a summary"} = Summarizer.summarize(log(), viewer, provider: Stub, respond_with: spy)
    assert_received {:captured, [_system, %{content: transcript}]}
    transcript
  end

  test "the omniscient summary is built from the full transcript" do
    transcript = capture(:omniscient)
    assert transcript =~ "POISON-IN-THE-WINE"
    assert transcript =~ "More wine?"
  end

  test "a character's summary is built only from what they witnessed" do
    # Otto heard the line but never saw Mira's thought — so it cannot be in the
    # transcript the summarizer sees, and thus cannot leak into otto's summary.
    transcript = capture({:character, "otto"})
    assert transcript =~ "More wine?"
    refute transcript =~ "POISON-IN-THE-WINE"
  end

  test "mira's own summary does include her interior" do
    transcript = capture({:character, "mira"})
    assert transcript =~ "POISON-IN-THE-WINE"
  end
end
