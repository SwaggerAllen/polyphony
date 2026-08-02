defmodule Polyphony.Authoring.EffectiveWorldBibleTest do
  @moduledoc "Folding canon world arc into the world bible (§2.8), with global/local scoping."
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.{WorldBible, WorldArcEntry, EffectiveWorldBible}

  defp e(attrs),
    do:
      struct(
        %WorldArcEntry{kind: :discovery, statement: "x", status: :canon, scope: :global},
        attrs
      )

  test "folds canon facts into starting_canon in beat order, after the authored canon" do
    bible = %WorldBible{starting_canon: ["The sea is cold."]}

    entries = [
      e(statement: "The moon fell.", beat: 3),
      e(statement: "The tide-gates broke.", beat: 1)
    ]

    out = EffectiveWorldBible.apply(bible, entries, :all)
    assert out.starting_canon == ["The sea is cold.", "The tide-gates broke.", "The moon fell."]
  end

  test "only canon applies — proposed and retracted are ignored" do
    entries = [
      e(statement: "canon fact"),
      e(statement: "nope", status: :proposed),
      e(statement: "gone", status: :retracted)
    ]

    assert EffectiveWorldBible.apply(%WorldBible{}, entries, :all).starting_canon == [
             "canon fact"
           ]
  end

  test "global facts reach everywhere; local facts only their location; omniscient sees all" do
    entries = [
      e(statement: "global fact", scope: :global),
      e(statement: "harbour murder", scope: :local, location_id: "the harbour")
    ]

    at_harbour = EffectiveWorldBible.apply(%WorldBible{}, entries, "the harbour").starting_canon
    assert "global fact" in at_harbour and "harbour murder" in at_harbour

    elsewhere = EffectiveWorldBible.apply(%WorldBible{}, entries, "the moor").starting_canon
    assert elsewhere == ["global fact"]

    # A scene with no location gets only global facts.
    nowhere = EffectiveWorldBible.apply(%WorldBible{}, entries, nil).starting_canon
    assert nowhere == ["global fact"]

    omni = EffectiveWorldBible.apply(%WorldBible{}, entries, :all).starting_canon
    assert "global fact" in omni and "harbour murder" in omni
  end
end
