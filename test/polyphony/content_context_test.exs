defmodule Polyphony.ContentContextTest do
  @moduledoc """
  §A5: the effective register is a **context-assembly input** — rendered into the
  frozen prefix and, composing with §A3, capping the boundary layer so the campaign
  ceiling overrides an `:open` boundary.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Context
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias Polyphony.Core.Content.CampaignConfig

  defp materialize(opts) do
    sheet = %CharacterSheet{
      name: "Mira",
      premise: "A guarded envoy.",
      boundaries: Keyword.get(opts, :boundaries, [])
    }

    Context.materialize(
      Keyword.merge(
        [
          scene_id: "s1",
          character_id: "mira",
          premise: "A room.",
          sheet: sheet,
          arc_entries: []
        ],
        Keyword.drop(opts, [:boundaries])
      )
    )
  end

  test "an enabled register is rendered into the prefix" do
    ctx =
      materialize(content_config: %CampaignConfig{adult_content: true, graphic_violence: true})

    assert ctx.prefix =~ "Content register enabled"
    assert ctx.prefix =~ "graphic violence"
  end

  test "the default (no adult content) config renders no register line" do
    ctx = materialize(content_config: %CampaignConfig{})
    refute ctx.prefix =~ "Content register"
  end

  test "the campaign ceiling forces an :open boundary closed when its category is off" do
    b = %Boundary{
      topic: "intimacy",
      stance: :open,
      category: :sexual,
      on_pressure: "she stiffens"
    }

    # Campaign has no adult content: the sexual boundary is capped to a hard line.
    gated = materialize(boundaries: [b], content_config: %CampaignConfig{})
    assert gated.prefix =~ "intimacy: a hard line"

    # Campaign enables the category: the boundary keeps its authored openness.
    released =
      materialize(
        boundaries: [b],
        content_config: %CampaignConfig{adult_content: true, sexual: true}
      )

    assert released.prefix =~ "intimacy: you are open to this."
  end

  test "a pure-characterization boundary is unaffected by the register (layers stay separate)" do
    b = %Boundary{topic: "betrayal", stance: :open, category: nil}
    ctx = materialize(boundaries: [b], content_config: %CampaignConfig{})
    assert ctx.prefix =~ "betrayal: you are open to this."
  end

  test "an unattested account floors every campaign toggle to nothing" do
    b = %Boundary{topic: "intimacy", stance: :open, category: :sexual}

    ctx =
      materialize(
        boundaries: [b],
        content_config: %CampaignConfig{adult_content: true, sexual: true},
        content_attested: false
      )

    refute ctx.prefix =~ "Content register enabled"
    assert ctx.prefix =~ "intimacy: a hard line"
  end

  describe "the Director is told the register too (§A5)" do
    test "no register arg → the plain Director brief" do
      assert Polyphony.Jobs.RunBeat.director_system_message(%{}) ==
               "You are the Director. Cast and pace the scene."
    end

    test "a register arg (category strings) appends the enabled register" do
      msg = Polyphony.Jobs.RunBeat.director_system_message(%{"content_register" => ["sexual"]})
      assert msg =~ "You are the Director."
      assert msg =~ "explicit sexual content"
    end
  end
end
