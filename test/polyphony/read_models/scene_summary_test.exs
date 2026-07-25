defmodule Polyphony.ReadModels.SceneSummaryTest do
  @moduledoc "Per-character summary storage + character-scoped vector search (§8)."
  use ExUnit.Case, async: true

  alias Polyphony.Repo
  alias Polyphony.ReadModels.SceneSummary
  alias Polyphony.SceneClose.MockEmbedder

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp embed(text), do: elem(MockEmbedder.embed(text), 1)

  test "stores and retrieves a character's own summary by vector similarity" do
    SceneSummary.put(Repo, "S1", "mira", "Mira learned the gate code", embed("gate code"))

    [hit] = SceneSummary.search(Repo, "mira", embed("gate code"), 5)
    assert hit.summary == "Mira learned the gate code"
  end

  test "search is scoped to the character — never returns another viewer's summary" do
    q = embed("shared premise")
    SceneSummary.put(Repo, "S1", "mira", "Mira's private recollection", q)
    SceneSummary.put(Repo, "S1", "otto", "Otto's private recollection", q)
    SceneSummary.put(Repo, "S1", SceneSummary.omniscient_key(), "The whole truth", q)

    mira = SceneSummary.search(Repo, "mira", q, 5)
    assert Enum.map(mira, & &1.character_id) == ["mira"]

    otto = SceneSummary.search(Repo, "otto", q, 5)
    assert Enum.map(otto, & &1.character_id) == ["otto"]
  end

  test "upserts on (scene, character) rather than duplicating" do
    SceneSummary.put(Repo, "S1", "mira", "first", embed("a"))
    SceneSummary.put(Repo, "S1", "mira", "second", embed("b"))

    rows = SceneSummary.search(Repo, "mira", embed("b"), 5)
    assert length(rows) == 1
    assert hd(rows).summary == "second"
  end
end
