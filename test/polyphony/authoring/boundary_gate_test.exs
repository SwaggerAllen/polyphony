defmodule Polyphony.Authoring.BoundaryGateTest do
  @moduledoc "§A3: resolving boundaries against canon arc; the conditional gate."
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.BoundaryGate
  alias Polyphony.Authoring.BoundaryGate.LLMEvaluator
  alias Polyphony.Authoring.CharacterSheet.Boundary

  defmodule YesProvider do
    @behaviour Polyphony.LLM.Provider
    def complete(_messages, _opts), do: {:ok, "yes"}
  end

  defmodule NoProvider do
    @behaviour Polyphony.LLM.Provider
    def complete(_messages, _opts), do: {:ok, "No.\n"}
  end

  defmodule FailProvider do
    @behaviour Polyphony.LLM.Provider
    def complete(_messages, _opts), do: {:error, :unavailable}
  end

  defp boundary(topic, stance, opts \\ []),
    do: %Boundary{
      topic: topic,
      stance: stance,
      condition: opts[:condition],
      on_pressure: opts[:on_pressure]
    }

  defp canon(statement), do: %{status: "canon", statement: statement}

  describe "resolve/3" do
    test "open is always released; closed never is" do
      assert [%{released: true}] = BoundaryGate.resolve([boundary("romance", :open)], [])
      assert [%{released: false}] = BoundaryGate.resolve([boundary("violence", :closed)], [])
    end

    test "a conditional releases only when the evaluator judges the condition met" do
      bs = [boundary("romance", :conditional, condition: "trust is established")]

      assert [%{released: true}] =
               BoundaryGate.resolve(bs, [canon("they trust each other")],
                 evaluator: fn _c, _s -> true end
               )

      assert [%{released: false}] =
               BoundaryGate.resolve(bs, [], evaluator: fn _c, _s -> false end)
    end

    test "a conditional with no condition stays gated" do
      assert [%{released: false}] =
               BoundaryGate.resolve([boundary("x", :conditional)], [],
                 evaluator: fn _c, _s -> true end
               )
    end

    test "the evaluator sees only canon statements (proposed/retracted excluded)" do
      spy = fn _c, statements ->
        send(self(), {:statements, statements})
        false
      end

      arc = [
        %{status: "canon", statement: "canon fact"},
        %{status: "proposed", statement: "a guess"},
        %{status: "retracted", statement: "wrong"}
      ]

      BoundaryGate.resolve([boundary("x", :conditional, condition: "c")], arc, evaluator: spy)
      assert_received {:statements, ["canon fact"]}
    end
  end

  describe "LLMEvaluator — fails closed" do
    test "yes → met, no → not met, provider error → not met (boundary holds)" do
      assert LLMEvaluator.met?("c", ["fact"], provider: YesProvider)
      refute LLMEvaluator.met?("c", ["fact"], provider: NoProvider)
      refute LLMEvaluator.met?("c", [], provider: FailProvider)
    end
  end
end
