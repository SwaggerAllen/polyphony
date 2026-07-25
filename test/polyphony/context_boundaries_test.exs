defmodule Polyphony.ContextBoundariesTest do
  @moduledoc """
  §A3: the resolved boundary state lands in the character's **frozen prefix**,
  framed in character — a refusal is generated as a scene beat, never a filter.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Context
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Boundary

  defp materialize(boundaries, arc, evaluator) do
    sheet = %CharacterSheet{name: "Mira", premise: "A guarded envoy.", boundaries: boundaries}

    Context.materialize(
      scene_id: "s1",
      character_id: "mira",
      premise: "A room.",
      sheet: sheet,
      arc_entries: arc,
      boundary_evaluator: evaluator
    )
  end

  test "no boundaries → no boundary section, and the evaluator is never called" do
    ctx = materialize([], [], fn _c, _s -> raise "should not evaluate" end)
    refute ctx.prefix =~ "Your boundaries"
  end

  test "a closed boundary is stated as a hard line, in character" do
    ctx =
      materialize(
        [%Boundary{topic: "romance", stance: :closed, on_pressure: "she deflects"}],
        [],
        nil
      )

    assert ctx.prefix =~ "romance: a hard line"
    assert ctx.prefix =~ "she deflects"
    # Characterization, not a filter: framed as a scene beat.
    assert ctx.prefix =~ "not a rule"
  end

  test "a conditional boundary reflects the resolved gate state from canon arc" do
    b = %Boundary{
      topic: "romance",
      stance: :conditional,
      condition: "trust is established",
      on_pressure: "she changes the subject"
    }

    gated = materialize([b], [], fn _c, _s -> false end)
    assert gated.prefix =~ "not until trust is established"
    assert gated.prefix =~ "she changes the subject"

    released =
      materialize([b], [%{status: "canon", statement: "they earned each other's trust"}], fn _c,
                                                                                             _s ->
        true
      end)

    assert released.prefix =~ "you are open to it now"
    refute released.prefix =~ "not until"
  end

  test "the boundary is in the character's messages — a refusal is generated, not filtered" do
    ctx = materialize([%Boundary{topic: "violence", stance: :closed}], [], nil)
    [%{role: "system", content: prefix} | _] = Context.to_messages(ctx)
    assert prefix =~ "violence: a hard line"
  end
end
