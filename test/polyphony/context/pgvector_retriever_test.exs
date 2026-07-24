defmodule Polyphony.Context.PgvectorRetrieverTest do
  @moduledoc """
  The pgvector retriever closes the memory gradient (§8, §9): scene-close writes
  per-character summaries, and scene-open materialization reads them back —
  scoped so a character only ever retrieves their own.
  """
  use ExUnit.Case, async: true

  alias Polyphony.{Repo, Context}
  alias Polyphony.Context.PgvectorRetriever
  alias Polyphony.ReadModels.SceneSummary
  alias Polyphony.SceneClose.MockEmbedder
  alias Polyphony.Authoring.CharacterSheet

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp embed(text), do: elem(MockEmbedder.embed(text), 1)

  defp sheet(name), do: %CharacterSheet{name: name, premise: "#{name} is here.", voice: "plain"}

  defp materialize(character_id, premise) do
    Context.materialize(
      scene_id: "S-new",
      character_id: character_id,
      sheet: sheet(character_id),
      premise: premise,
      retriever: PgvectorRetriever
    )
  end

  test "a character's own distant summaries are retrieved into the frozen prefix" do
    # The embedding is derived from the premise, so store the summary under the
    # premise text to guarantee it's the nearest neighbor.
    SceneSummary.put(Repo, "S0", "mira", "Mira met the duke in the cellar", embed("the duke"))

    ctx = materialize("mira", "the duke")
    assert ctx.prefix =~ "Mira met the duke in the cellar"
  end

  test "retrieval is scoped — a character never pulls another viewer's summary" do
    SceneSummary.put(Repo, "S0", "mira", "MIRA-ONLY memory", embed("shared"))
    SceneSummary.put(Repo, "S0", "otto", "OTTO-ONLY memory", embed("shared"))

    SceneSummary.put(
      Repo,
      "S0",
      SceneSummary.omniscient_key(),
      "THE-WHOLE-TRUTH",
      embed("shared")
    )

    mira = materialize("mira", "shared")
    assert mira.prefix =~ "MIRA-ONLY memory"
    refute mira.prefix =~ "OTTO-ONLY memory"
    refute mira.prefix =~ "THE-WHOLE-TRUTH"
  end

  test "no summaries yet is fine — the prefix just omits the section" do
    ctx = materialize("nobody", "a premise")
    assert is_binary(ctx.prefix)
    refute ctx.prefix =~ "Earlier (summarized)"
  end
end
