defmodule Polyphony.SuggestTest do
  @moduledoc "Suggestion mode (§11): variants from the character's filtered view."
  use ExUnit.Case, async: true

  import Polyphony.Test.Scenario
  alias Polyphony.{Context, Suggest}
  alias Polyphony.LLM.Mock
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.TurnPacket

  defp context do
    sheet = %CharacterSheet{name: "You", premise: "The user's character.", voice: "plain"}
    Context.materialize(scene_id: "S1", character_id: "user", sheet: sheet, premise: "A room.")
  end

  test "produces the requested number of editable variants" do
    assert {:ok, variants} = Suggest.variants(context: context(), provider: Mock, count: 3)
    assert length(variants) == 3
    assert Enum.all?(variants, &match?(%TurnPacket{}, &1))
  end

  test "variants are distinct (drafted from different option prompts)" do
    {:ok, [a, b, c]} = Suggest.variants(context: context(), provider: Mock, count: 3)
    speech = fn p -> Enum.find(p.moves, &(&1.type == :speech)).content end
    refute speech.(a) == speech.(b) and speech.(b) == speech.(c)
  end

  test "suggestions come from the FILTERED view — never reference what the character didn't witness" do
    # The log contains another character's private thought. The user's character
    # is present for the speech but structurally never saw the thought, so the
    # suggestion context (and thus any honest suggestion) cannot contain it.
    live = [
      entered("S1", "user", 1),
      entered("S1", "villain", 1),
      thought("villain", "S1", 2, "POISON-IN-THE-WINE-secret"),
      speech("villain", "S1", 2, "More wine?")
    ]

    # Assert on the assembled context directly: the filtered guard is what makes
    # every downstream suggestion honest.
    [_system, %{content: user_msg}] =
      Context.to_messages(context(), live_events: live, members: ["user", "villain"])

    assert user_msg =~ "More wine?"
    refute user_msg =~ "POISON-IN-THE-WINE-secret"

    assert {:ok, _variants} =
             Suggest.variants(
               context: context(),
               live_events: live,
               members: ["user", "villain"],
               provider: Mock
             )
  end

  test "accepts an optional steer" do
    assert {:ok, variants} =
             Suggest.variants(
               context: context(),
               provider: Mock,
               count: 2,
               steer: "keep it brief"
             )

    assert length(variants) == 2
  end

  test "requires a context" do
    assert_raise ArgumentError, fn -> Suggest.variants(provider: Mock) end
  end

  defmodule FailProvider do
    @behaviour Polyphony.LLM.Provider
    @impl true
    def complete(_messages, _opts), do: {:error, {:http_status, 429, "busy"}}
  end

  test "surfaces the underlying failure reason when no variant succeeds" do
    assert {:error, {:no_variants, {:provider, {:http_status, 429, "busy"}}}} =
             Suggest.variants(context: context(), provider: FailProvider, count: 1)
  end
end
