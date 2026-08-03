defmodule Polyphony.Authoring.EffectiveWorldBibleTest do
  @moduledoc "Folding canon world arc into the world bible (§2.8), with global/local scoping."
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.{WorldBible, WorldArcEntry, EffectiveWorldBible}

  # Canon is a list of `WorldBible.Entry` now, so read it back through the accessor —
  # which is also the point: a folded world-arc fact is a *public* entry, since reach
  # (`scope`) and concealment are different axes and arc has no way to be concealed yet.
  defp canon(bible), do: WorldBible.statements(bible.starting_canon)

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
    assert canon(out) == ["The sea is cold.", "The tide-gates broke.", "The moon fell."]
  end

  test "only canon applies — proposed and retracted are ignored" do
    entries = [
      e(statement: "canon fact"),
      e(statement: "nope", status: :proposed),
      e(statement: "gone", status: :retracted)
    ]

    assert canon(EffectiveWorldBible.apply(%WorldBible{}, entries, :all)) == ["canon fact"]
  end

  test "global facts reach everywhere; local facts only their location; omniscient sees all" do
    entries = [
      e(statement: "global fact", scope: :global),
      e(statement: "harbour murder", scope: :local, location_id: "the harbour")
    ]

    at_harbour = canon(EffectiveWorldBible.apply(%WorldBible{}, entries, "the harbour"))
    assert "global fact" in at_harbour and "harbour murder" in at_harbour

    elsewhere = canon(EffectiveWorldBible.apply(%WorldBible{}, entries, "the moor"))
    assert elsewhere == ["global fact"]

    # A scene with no location gets only global facts.
    nowhere = canon(EffectiveWorldBible.apply(%WorldBible{}, entries, nil))
    assert nowhere == ["global fact"]

    omni = canon(EffectiveWorldBible.apply(%WorldBible{}, entries, :all))
    assert "global fact" in omni and "harbour murder" in omni
  end
end
