defmodule Polyphony.ContentTest do
  @moduledoc """
  §A5: content governance as three nested layers. The invariant tested hardest is
  **nesting** — a narrower layer restricts within a broader one and never expands
  past it (the content analogue of default-deny visibility).
  """
  use ExUnit.Case, async: true

  alias Polyphony.Content
  alias Polyphony.Content.{CampaignConfig, Floor}
  alias Polyphony.Authoring.CharacterSheet.Boundary

  describe "CampaignConfig.enabled/1 — the master toggle gates the sub-toggles" do
    test "adult_content off ⇒ empty, whatever the sub-toggles say" do
      config = %CampaignConfig{adult_content: false, sexual: true, graphic_violence: true}
      assert CampaignConfig.enabled(config) == []
    end

    test "adult_content on ⇒ only the sub-toggles that are set" do
      config = %CampaignConfig{adult_content: true, sexual: true, graphic_violence: false}
      assert CampaignConfig.enabled(config) == [:sexual]
    end

    test "the default config enables nothing" do
      assert CampaignConfig.enabled(%CampaignConfig{}) == []
    end

    test "from_payload reads the stored config, defaulting for legacy campaigns" do
      config = %CampaignConfig{adult_content: true, sexual: true}
      assert CampaignConfig.from_payload(%{content_config: config}) == config
      # A campaign that predates the setting (or a plain-map payload) → all-off default.
      assert CampaignConfig.from_payload(%{name: "old"}) == %CampaignConfig{}

      assert CampaignConfig.from_payload(%{
               content_config: %{"adult_content" => true, "other" => true}
             }) ==
               %CampaignConfig{adult_content: true, other: true}
    end

    test "label summarizes the enabled register" do
      assert CampaignConfig.label(%CampaignConfig{}) == "No adult content"

      assert CampaignConfig.label(%CampaignConfig{adult_content: true, sexual: true}) ==
               "Adult content: sexual"
    end
  end

  describe "Floor.register/1 — the outermost 18+ ceiling" do
    test "an attested account floors to every category" do
      assert Floor.register(attested: true) == Content.categories()
    end

    test "an unattested account floors to nothing" do
      assert Floor.register(attested: false) == []
    end
  end

  describe "register/2 — floor ∩ campaign, the nesting intersection" do
    test "campaign off collapses to empty even under the full floor" do
      assert Content.register(%CampaignConfig{adult_content: false}, attested: true) == []
    end

    test "an enabled campaign is capped by the floor, never expanded past it" do
      config = %CampaignConfig{adult_content: true, sexual: true, graphic_violence: true}
      # Attested: both flow through.
      assert Content.register(config, attested: true) == [:sexual, :graphic_violence]
      # Unattested floor is empty: the narrower campaign cannot expand past it.
      assert Content.register(config, attested: false) == []
    end
  end

  describe "gate_boundary/2 — layer 2 caps layer 3, without conflating them" do
    test "a category the register disables forces the boundary closed, overriding :open" do
      b = %Boundary{topic: "intimacy", stance: :open, category: :sexual}
      assert %Boundary{stance: :closed} = Content.gate_boundary(b, [])
    end

    test "a permitted category passes the boundary through untouched" do
      b = %Boundary{topic: "intimacy", stance: :open, category: :sexual}
      assert Content.gate_boundary(b, [:sexual]) == b
    end

    test "a pure-characterization boundary (no category) is never touched by the register" do
      b = %Boundary{topic: "betrayal", stance: :open, category: nil}
      assert Content.gate_boundary(b, []) == b
    end
  end

  describe "constrain_boundary/2 — the authoring-time editor rule (FS §V8a)" do
    test "permitted → {:ok, boundary}; forbidden → {:constrained, forced_closed}" do
      permitted = %Boundary{topic: "intimacy", stance: :conditional, category: :sexual}
      assert {:ok, ^permitted} = Content.constrain_boundary(permitted, [:sexual])

      forbidden = %Boundary{topic: "intimacy", stance: :open, category: :sexual}

      assert {:constrained, %Boundary{stance: :closed}} =
               Content.constrain_boundary(forbidden, [])
    end
  end

  describe "render_register/1 — the context-assembly input" do
    test "empty register renders nothing (ordinary limits need no announcement)" do
      assert Content.render_register([]) == nil
    end

    test "an enabled register names the categories and keeps the layers distinct" do
      line = Content.render_register([:sexual, :graphic_violence])
      assert line =~ "explicit sexual content"
      assert line =~ "graphic violence"
      # Distinct from boundaries: register is 'permitted at all', not 'this character engages'.
      assert line =~ "boundaries still govern whether they engage"
    end
  end

  describe "cast_categories/1 — normalizing args to known atoms" do
    test "keeps known strings/atoms, drops the rest" do
      assert Content.cast_categories(["sexual", :graphic_violence, "bogus", 42]) ==
               [:sexual, :graphic_violence]
    end
  end
end
