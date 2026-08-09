defmodule Polyphony.Authoring.EffectiveSheetAuthoredTest do
  @moduledoc """
  Authored arc entries folding into the effective sheet (STR-62): the list
  operations (add / change / remove), satisfaction as a release, and the
  *always true* timing folding before everything play has done.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.{Audience, CharacterSheet, EffectiveSheet, ArcEntry}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Fact, Relationship}

  defp base do
    %CharacterSheet{
      name: "Wren",
      temperament: "guarded",
      facts: [
        %Fact{statement: "She reads every manifest twice."},
        %Fact{statement: "She has stopped signing the register in her mother's hand."}
      ],
      boundaries: [
        %Boundary{
          topic: "Won't say who signed for the shipment",
          stance: :conditional,
          condition: "Someone she loves is going to be hurt by the silence.",
          after_release: "She says it flatly, in public.",
          direction: :refusal
        }
      ],
      relationships: [
        %Relationship{target: "Aldous", target_id: "p9", descriptor: "Covers for him."}
      ]
    }
  end

  defp canon(entry), do: %ArcEntry{entry | status: :canon}

  test "an authored fact add carries its audience and always-in-mind flag" do
    audience = %Audience{character_ids: ["p2"]}

    entry =
      canon(%ArcEntry{
        kind: :discovery,
        sheet_field: "facts",
        statement: "She has taken to carrying her father's key.",
        operation: :add,
        core: true,
        concealed: true,
        audience: audience,
        author: "allen"
      })

    effective = EffectiveSheet.apply(base(), [entry])
    added = Enum.find(effective.facts, &(&1.statement =~ "father's key"))

    assert %Fact{core: true, concealed: true, audience: ^audience} = added
  end

  test "an authored fact change supersedes the one `replaces` names, and only it" do
    entry =
      canon(%ArcEntry{
        kind: :revision,
        sheet_field: "facts",
        statement: "She has stopped signing the register at all.",
        replaces: "She has stopped signing the register in her mother's hand.",
        operation: :change
      })

    effective = EffectiveSheet.apply(base(), [entry])

    assert Enum.any?(
             effective.facts,
             &(&1.statement == "She has stopped signing the register at all.")
           )

    refute Enum.any?(effective.facts, &(&1.statement =~ "mother's hand"))
    assert Enum.any?(effective.facts, &(&1.statement == "She reads every manifest twice."))
  end

  test "removing a fact stops carrying it forward without touching the rest" do
    entry =
      canon(%ArcEntry{
        kind: :revision,
        sheet_field: "facts",
        statement: "She reads every manifest twice.",
        replaces: "She reads every manifest twice.",
        operation: :remove
      })

    effective = EffectiveSheet.apply(base(), [entry])

    refute Enum.any?(effective.facts, &(&1.statement =~ "manifest"))
    assert Enum.any?(effective.facts, &(&1.statement =~ "mother's hand"))
  end

  test "an authored line with an until is earnable; without one it is a never" do
    earnable =
      canon(%ArcEntry{
        kind: :discovery,
        sheet_field: "boundaries",
        statement: "Can't stop covering for her father.",
        direction: :compulsion,
        line_condition: "Someone she loves is going to be hurt by the silence.",
        after_release: "She lets the silences sit.",
        operation: :add
      })

    never =
      canon(%ArcEntry{
        kind: :discovery,
        sheet_field: "boundaries",
        statement: "Won't let anyone be turned away from the chapel.",
        direction: :refusal,
        operation: :add
      })

    effective = EffectiveSheet.apply(base(), [earnable, never])

    assert %Boundary{
             stance: :conditional,
             direction: :compulsion,
             after_release: "She lets the silences sit."
           } =
             Enum.find(effective.boundaries, &(&1.topic =~ "covering"))

    assert %Boundary{stance: :closed, direction: :refusal, condition: nil} =
             Enum.find(effective.boundaries, &(&1.topic =~ "chapel"))
  end

  test "an authored satisfaction is a release: the line opens" do
    entry =
      canon(%ArcEntry{
        kind: :release,
        sheet_field: "boundaries",
        statement: "She says it flatly, in public.",
        released_topic: "Won't say who signed for the shipment",
        operation: :satisfied,
        condition_met: true,
        author: "allen"
      })

    effective = EffectiveSheet.apply(base(), [entry])

    assert %Boundary{stance: :open} =
             Enum.find(effective.boundaries, &(&1.topic =~ "shipment"))
  end

  test "removing a relationship ends one direction only" do
    entry =
      canon(%ArcEntry{
        kind: :revision,
        sheet_field: "relationships",
        statement: "",
        target_id: "p9",
        operation: :remove
      })

    effective = EffectiveSheet.apply(base(), [entry])
    assert effective.relationships == []
  end

  test "changing a relationship rewrites the regard of the direction it names" do
    entry =
      canon(%ArcEntry{
        kind: :revision,
        sheet_field: "relationships",
        statement: "She has started asking, and doesn't like the answers.",
        target_id: "p9",
        operation: :change
      })

    effective = EffectiveSheet.apply(base(), [entry])

    assert [
             %Relationship{
               target_id: "p9",
               descriptor: "She has started asking, and doesn't like the answers."
             }
           ] =
             effective.relationships
  end

  test "always-true timing folds before everything play has done, whatever its beat" do
    play =
      canon(%ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "hardened by the spring tides",
        beat: 2
      })

    origin_fix =
      canon(%ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "soft-spoken, not guarded",
        timing: :always,
        author: "allen",
        beat: 9
      })

    # The origin correction sits under play's change: history stays and applies
    # on top, so play's later revision still wins the field.
    assert %CharacterSheet{temperament: "hardened by the spring tides"} =
             EffectiveSheet.apply(base(), [play, origin_fix])

    # Alone, the correction is the field.
    assert %CharacterSheet{temperament: "soft-spoken, not guarded"} =
             EffectiveSheet.apply(base(), [origin_fix])
  end
end
