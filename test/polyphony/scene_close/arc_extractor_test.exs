defmodule Polyphony.SceneClose.ArcExtractorTest do
  @moduledoc "Arc extraction (§6.2): proposed-only, filtered, schema-validated."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias Polyphony.SceneClose.ArcExtractor
  alias Polyphony.LLM.{Mock, Stub}
  alias Polyphony.Authoring.ArcEntry

  defp log do
    [
      entered("S1", "mira", 1),
      thought("mira", "S1", 2, "I will not forgive this"),
      speech("mira", "S1", 2, "Understood.")
    ]
  end

  test "extracts proposed arc entries tagged with the source scene" do
    assert {:ok, entries} =
             ArcExtractor.extract(log(), "mira", provider: Mock, source_scene_id: "S1")

    assert [%ArcEntry{status: :proposed, source_scene_id: "S1"} | _] = entries
    assert Enum.all?(entries, &(&1.status == :proposed))
  end

  test "invalid output is surfaced as an error, not a crash" do
    assert {:error, :invalid_arc} =
             ArcExtractor.extract(log(), "mira", provider: Stub, respond_with: {:ok, "not json"})
  end

  test "the extraction is scoped to the character's filtered view" do
    spy = fn messages ->
      send(self(), {:captured, messages})
      {:ok, ~s({"entries":[]})}
    end

    # bram was never in the scene; his extraction sees none of it.
    {:ok, _} = ArcExtractor.extract(log(), "bram", provider: Stub, respond_with: spy)
    assert_received {:captured, [_system, %{content: transcript}]}
    refute transcript =~ "I will not forgive this"
    refute transcript =~ "Understood."
  end
end
