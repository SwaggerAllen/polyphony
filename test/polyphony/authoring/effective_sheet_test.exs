defmodule Polyphony.Authoring.EffectiveSheetTest do
  @moduledoc "Materializing the effective sheet from canon arc entries (§5)."
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.{CharacterSheet, EffectiveSheet, ArcEntry}
  alias Polyphony.Authoring.CharacterSheet.Fact

  defp base do
    %CharacterSheet{
      name: "Mira",
      temperament: "guarded",
      initial_knowledge: ["the duke is ill"],
      facts: [%Fact{statement: "keeps a dagger", core: true}]
    }
  end

  test "a canon revision overrides the authored scalar field" do
    entries = [
      %ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "hardened, no longer guarded",
        status: :canon,
        beat: 4
      }
    ]

    assert %CharacterSheet{temperament: "hardened, no longer guarded"} =
             EffectiveSheet.apply(base(), entries)
  end

  test "a free-standing canon discovery is promoted to a fact (union)" do
    entries = [
      %ArcEntry{
        kind: :discovery,
        sheet_field: nil,
        statement: "has a sister named Mira",
        status: :canon,
        beat: 3
      }
    ]

    effective = EffectiveSheet.apply(base(), entries)
    assert Enum.any?(effective.facts, &(&1.statement == "has a sister named Mira"))
    # The original fact is retained (union, not replace).
    assert Enum.any?(effective.facts, &(&1.statement == "keeps a dagger"))
  end

  test "a discovery targeting initial_knowledge unions into it" do
    entries = [
      %ArcEntry{
        kind: :discovery,
        sheet_field: "initial_knowledge",
        statement: "the gate code is 1-1-9",
        status: :canon
      }
    ]

    effective = EffectiveSheet.apply(base(), entries)
    assert "the gate code is 1-1-9" in effective.initial_knowledge
    assert "the duke is ill" in effective.initial_knowledge
  end

  test "proposed and retracted entries are ignored — only canon applies" do
    entries = [
      %ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "reckless",
        status: :proposed,
        beat: 1
      },
      %ArcEntry{kind: :discovery, statement: "secretly royalty", status: :retracted, beat: 2}
    ]

    effective = EffectiveSheet.apply(base(), entries)
    assert effective.temperament == "guarded"
    refute Enum.any?(effective.facts, &(&1.statement == "secretly royalty"))
  end

  test "revisions apply in beat order (later wins)" do
    entries = [
      %ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "first",
        status: :canon,
        beat: 5
      },
      %ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "second",
        status: :canon,
        beat: 9
      }
    ]

    assert %CharacterSheet{temperament: "second"} = EffectiveSheet.apply(base(), entries)
  end
end
