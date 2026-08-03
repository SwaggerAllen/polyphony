defmodule Polyphony.Authoring.CompulsionTest do
  @moduledoc """
  The second direction a character can be pushed — *what they can't stop doing*.

  `ux/polyphony-character.html` §05 asks for two lists, not one, and argues the
  grouping is the whole point: **direction lives in the grouping, not the wording**,
  so an item can never be read backwards — which is exactly what went wrong when
  everything was one list of "lines". `Boundary` modelled only refusals, and the
  backlog pass never recorded the gap, so this pins the axis end to end.

  The mechanic is deliberately *not* duplicated. `stance` still answers one question
  — does the gate hold? — and `direction` says what holding means. A held refusal is
  "she won't"; a held compulsion is "she can't stop".

  The case worth the most care is the ceiling. Capping used to mean `stance: :closed`,
  which for a compulsion means *she always does it* — so a naive cap would have made
  the content ceiling **compel** the content it exists to forbid. The design states
  the rule outright: *the ceiling always pushes toward refusal. That's the correct
  direction to fail in.*
  """
  use ExUnit.Case, async: true

  alias Polyphony.Content
  alias Polyphony.Authoring.BoundaryGate
  alias Polyphony.Authoring.CharacterSheet.Boundary

  defp compulsion(attrs),
    do: struct(%Boundary{topic: "Cover for her father", direction: :compulsion}, attrs)

  defp refusal(attrs),
    do: struct(%Boundary{topic: "Name her father", direction: :refusal}, attrs)

  describe "the axis" do
    test "a boundary is a refusal unless it says otherwise" do
      assert %Boundary{direction: :refusal} = %Boundary{topic: "Leave Saltmarch"}
    end

    test "from_map reads the direction, and anything it doesn't recognise is a refusal" do
      assert Boundary.from_map(%{"topic" => "x", "direction" => "compulsion"}).direction ==
               :compulsion

      assert Boundary.from_map(%{"topic" => "x", "direction" => "refusal"}).direction == :refusal
      assert Boundary.from_map(%{"topic" => "x", "direction" => "sideways"}).direction == :refusal
      assert Boundary.from_map(%{"topic" => "x"}).direction == :refusal
    end

    test "from_map carries the after-state through" do
      b = Boundary.from_map(%{"topic" => "x", "after_release" => "She lets the silences sit."})
      assert b.after_release == "She lets the silences sit."
      assert Boundary.from_map(%{"topic" => "x", "after_release" => "  "}).after_release == nil
    end

    test "the two are labelled as the sheet's two headings" do
      assert Boundary.direction_label(:refusal) =~ "won't"
      assert Boundary.direction_label(:compulsion) =~ "can't stop"
      assert Boundary.directions() == [:refusal, :compulsion]
    end
  end

  describe "the gate is the same gate" do
    test "direction doesn't change whether a condition releases it" do
      met = fn _c, _s -> true end
      unmet = fn _c, _s -> false end
      cond_attrs = [stance: :conditional, condition: "she sees what it cost"]

      for b <- [refusal(cond_attrs), compulsion(cond_attrs)] do
        assert [%{released: true}] = BoundaryGate.resolve([b], [], evaluator: met)
        assert [%{released: false}] = BoundaryGate.resolve([b], [], evaluator: unmet)
      end
    end

    test "a closed compulsion never releases, same as a closed refusal" do
      assert [%{released: false}] =
               BoundaryGate.resolve([compulsion(stance: :closed)], [],
                 evaluator: fn _, _ -> true end
               )
    end
  end

  describe "the content ceiling caps toward refusal" do
    test "capping a compulsion flips it, so the ceiling can't compel what it forbids" do
      c = compulsion(topic: "Cut someone", stance: :closed, category: :graphic_violence)

      capped = Content.gate_boundary(c, [])

      assert capped.direction == :refusal,
             "a capped compulsion left as a compulsion means the character always does it"

      assert capped.stance == :closed
      assert capped.topic == "Cut someone"
    end

    test "capping an open compulsion holds it too — stance can't reopen disabled content" do
      c = compulsion(topic: "Cut someone", stance: :open, category: :graphic_violence)

      assert %Boundary{direction: :refusal, stance: :closed} = Content.gate_boundary(c, [])
    end

    test "capping a refusal is unchanged — for that direction closed already meant won't" do
      r = refusal(topic: "Kill", stance: :conditional, category: :graphic_violence)

      assert %Boundary{direction: :refusal, stance: :closed} = Content.gate_boundary(r, [])
    end

    test "a permitted category passes through with its direction intact" do
      c = compulsion(topic: "Cut someone", stance: :conditional, category: :graphic_violence)

      assert Content.gate_boundary(c, [:graphic_violence]) == c
    end

    test "pure characterization is never touched, in either direction" do
      c = compulsion(stance: :conditional, condition: "x")
      assert Content.gate_boundary(c, []) == c
    end

    test "the authoring-time constraint caps identically" do
      c = compulsion(topic: "Cut someone", stance: :open, category: :graphic_violence)

      assert {:constrained, %Boundary{direction: :refusal, stance: :closed}} =
               Content.constrain_boundary(c, [])

      assert {:ok, ^c} = Content.constrain_boundary(c, [:graphic_violence])
    end
  end

  describe "what the character is told" do
    alias Polyphony.Authoring.CharacterSheet
    alias Polyphony.Context

    defp prose(boundaries, evaluator) do
      Context.materialize(%{
        sheet: %CharacterSheet{name: "Wren", boundaries: boundaries},
        character_id: "wren",
        scene_id: "S1",
        boundary_evaluator: evaluator
      })
      |> Map.get(:prefix)
    end

    test "a held compulsion is written as a compulsion, not as a negated refusal" do
      text =
        prose(
          [compulsion(stance: :conditional, condition: "she sees what it cost")],
          fn _, _ -> false end
        )

      assert text =~ "you can't stop"
      refute text =~ "you will not — not until she sees what it cost"
    end

    test "a held refusal still reads as a refusal" do
      text =
        prose([refusal(stance: :conditional, condition: "someone is hurt")], fn _, _ -> false end)

      assert text =~ "you will not"
    end

    test "resisting a compulsion is a different pressure from pushing a refusal" do
      text =
        prose(
          [compulsion(stance: :closed, on_pressure: "She signs it later, alone.")],
          fn _, _ -> false end
        )

      assert text =~ "you always do this"
      assert text =~ "When someone tries to stop you: She signs it later, alone."
    end

    test "she is NOT told the after-state while the gate still holds" do
      held =
        compulsion(
          stance: :conditional,
          condition: "she sees what it cost",
          after_release: "She lets the silences sit."
        )

      refute prose([held], fn _, _ -> false end) =~ "She lets the silences sit."
    end

    test "she IS told it once it has turned — that's when it's true of her" do
      released =
        compulsion(
          stance: :conditional,
          condition: "she sees what it cost",
          after_release: "She lets the silences sit."
        )

      text = prose([released], fn _, _ -> true end)
      assert text =~ "it no longer holds you"
      assert text =~ "Since then: She lets the silences sit."
    end

    test "a released refusal carries its after-state too" do
      released =
        refusal(
          stance: :conditional,
          condition: "someone she loves is hurt by the silence",
          after_release: "She says it flatly, in public."
        )

      text = prose([released], fn _, _ -> true end)
      assert text =~ "you are open to it now"
      assert text =~ "Since then: She says it flatly, in public."
    end
  end
end
