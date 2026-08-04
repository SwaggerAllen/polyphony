defmodule Polyphony.Authoring.AutofillTest do
  @moduledoc """
  Author-facing generation: whole-form from a brief, one field from the others, for
  both character and world-bible kinds. Driven by the offline Mock (deterministic)
  plus the Stub for exercising the JSON-extraction edge cases.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.Autofill

  @mock [provider: Polyphony.LLM.Mock]

  describe "generate_all/4" do
    test "fills every character field from a brief" do
      assert {:ok, values} = Autofill.generate_all(:character, "a tired sea captain", %{}, @mock)

      for {name, _t, _g} <- Autofill.fields(:character) do
        assert is_binary(values[name]) and values[name] != "", "expected #{name} to be filled"
      end
    end

    test "fills every world-bible field, including the list-typed ones" do
      assert {:ok, values} = Autofill.generate_all(:world_bible, "a drowned city", %{}, @mock)
      assert Map.has_key?(values, "setting")
      assert Map.has_key?(values, "rules")
      assert Map.has_key?(values, "starting_canon")
    end

    test "tolerates a model that wraps the JSON in a code fence" do
      fenced =
        {:ok,
         "```json\n" <>
           Jason.encode!(%{"name" => "Ada", "premise" => "A lighthouse keeper."}) <> "\n```"}

      opts = [provider: Polyphony.LLM.Stub, respond_with: fenced]
      assert {:ok, values} = Autofill.generate_all(:character, "x", %{}, opts)
      assert values["name"] == "Ada"
      assert values["premise"] == "A lighthouse keeper."
    end

    test "tolerates a model that surrounds the JSON with prose" do
      wrapped = {:ok, ~s(Sure, here you go: {"tone": "elegiac"} — hope that helps!)}
      opts = [provider: Polyphony.LLM.Stub, respond_with: wrapped]
      assert {:ok, values} = Autofill.generate_all(:world_bible, "x", %{}, opts)
      assert values["tone"] == "elegiac"
    end

    test "surfaces undecodable output as an error rather than crashing" do
      opts = [provider: Polyphony.LLM.Stub, respond_with: {:ok, "no json here"}]
      assert {:error, :invalid_json} = Autofill.generate_all(:character, "x", %{}, opts)
    end
  end

  describe "world seeding" do
    @world %{
      "name" => "Neon Bay",
      "setting" => "a drowned port city",
      "tone" => "noir",
      "rules" => "memory can be sold",
      "starting_canon" => ""
    }

    test "the world context is injected into the whole-form prompt" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_all(:character, "a smuggler", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            world: @world
          )
        end)

      assert msgs =~ "Neon Bay"
      assert msgs =~ "a drowned port city"
      assert msgs =~ "memory can be sold"
    end

    test "characters about to be cast reach the world prompt, named as not-to-name" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_all(:world_bible, "a rain-drowned harbour city", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            cast_seeds: ["a disgraced harbour-master", "the collector who bought her past"]
          )
        end)

      # The seeds themselves, so the world is written around people who are coming.
      assert msgs =~ "a disgraced harbour-master"
      assert msgs =~ "the collector who bought her past"

      # And the constraint that is the whole point. Written blind, a world that needs a
      # harbour-master invents one, names her into `starting_canon`, and the next phase
      # generates that same seed as somebody else — the campaign opens with two of her.
      assert msgs =~ "not yours to write"
      assert msgs =~ "Do not name them"
    end

    test "no seeds means no block, rather than an empty heading" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_all(:world_bible, "a harbour city", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            cast_seeds: ["", "   "]
          )
        end)

      # The bible editor's own "write the whole bible" passes none at all, and a row
      # left blank in Quick Build is still a row — neither should spend prompt on an
      # instruction about nobody.
      refute msgs =~ "about to write these characters"
    end

    test "the world context is injected into the single-field prompt" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_field(:character, "backstory", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            world: @world
          )
        end)

      assert msgs =~ "Neon Bay"
      assert msgs =~ "noir"
    end

    test "related character sheets are injected into the prompt" do
      relations = [
        %{
          "name" => "Bram",
          "descriptor" => "estranged mentor",
          "premise" => "a retired duelist who taught her everything",
          "voice" => "clipped",
          "temperament" => "stoic",
          "backstory" => "left the guild in disgrace"
        }
      ]

      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_field(:character, "backstory", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            relations: relations
          )
        end)

      assert msgs =~ "Related characters"
      assert msgs =~ "Bram"
      assert msgs =~ "estranged mentor"
      assert msgs =~ "a retired duelist who taught her everything"
    end

    test "no world context leaves the prompt clean (no dangling label)" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_field(:character, "backstory", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            world: nil
          )
        end)

      refute msgs =~ "World context"
    end

    test "a stub's inherited role is injected into generation" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_field(:character, "backstory", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            role: "estranged mentor"
          )
        end)

      assert msgs =~ "estranged mentor"
      assert msgs =~ "Honor that role"
    end

    test "no role leaves the prompt clean (no dangling label)" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_field(:character, "backstory", %{},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            role: nil
          )
        end)

      refute msgs =~ "Honor that role"
    end

    # Runs `fun` with a capturing `respond_with` and returns the concatenated
    # prompt content the provider saw.
    defp capture_prompt(fun) do
      test_pid = self()

      capture = fn messages ->
        send(test_pid, {:prompt, messages})
        {:ok, ~s({"backstory":"x"})}
      end

      fun.(capture)
      assert_received {:prompt, messages}
      Enum.map_join(messages, "\n", & &1.content)
    end
  end

  describe "generate_paragraph/3" do
    test "rewrites the paragraph at a given index" do
      assert {:ok, para} =
               Autofill.generate_paragraph(:character, "backstory",
                 blocks: ["orphaned young", "joined the guard"],
                 index: 0,
                 provider: Polyphony.LLM.Mock
               )

      assert is_binary(para) and para != ""
    end

    test "with no index, writes a fresh paragraph to append (expand)" do
      assert {:ok, para} =
               Autofill.generate_paragraph(:character, "backstory",
                 blocks: ["orphaned young"],
                 index: nil,
                 provider: Polyphony.LLM.Mock
               )

      assert is_binary(para) and para != ""
    end

    test "the expand prompt asks not to repeat existing content" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.generate_paragraph(:character, "backstory",
            blocks: ["She was orphaned in the flood."],
            index: nil,
            provider: Polyphony.LLM.Stub,
            respond_with: capture
          )
        end)

      assert msgs =~ "NEW paragraph"
      assert msgs =~ "do not repeat"
      assert msgs =~ "She was orphaned in the flood."
    end

    test "rejects an unknown field" do
      assert {:error, {:unknown_field, "nope"}} =
               Autofill.generate_paragraph(:character, "nope", provider: Polyphony.LLM.Mock)
    end
  end

  describe "suggest_boundaries/2" do
    test "returns normalized boundary maps (topic + valid stance/category)" do
      assert {:ok, boundaries} =
               Autofill.suggest_boundaries(%{"name" => "Mira", "premise" => "a wary smuggler"},
                 provider: Polyphony.LLM.Mock
               )

      assert is_list(boundaries) and boundaries != []
      assert Enum.all?(boundaries, &(is_binary(&1["topic"]) and &1["topic"] != ""))
      # Generated boundaries are always conditional slow-burns, each with a condition.
      assert Enum.all?(boundaries, &(&1["stance"] == "conditional"))
      assert Enum.all?(boundaries, &(&1["condition"] != ""))

      assert Enum.all?(
               boundaries,
               &(&1["category"] in ["", "sexual", "graphic_violence", "other"])
             )
    end

    test "any returned stance is normalized to conditional, and category to a valid one" do
      array =
        {:ok,
         Jason.encode!([
           %{
             "topic" => "killing",
             "stance" => "closed",
             "category" => "gore",
             "condition" => "the siege leaves no other way out"
           }
         ])}

      assert {:ok, [b]} =
               Autofill.suggest_boundaries(%{"name" => "Mira"},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )

      assert b["stance"] == "conditional"
      assert b["category"] == ""
    end

    test "a boundary with no condition is dropped (never generated without one)" do
      array =
        {:ok,
         Jason.encode!([
           %{"topic" => "killing", "condition" => ""},
           %{"topic" => "intimacy", "condition" => "once real trust is earned"}
         ])}

      assert {:ok, [%{"topic" => "intimacy"}]} =
               Autofill.suggest_boundaries(%{"name" => "Mira"},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )
    end

    test "excludes topics the character already holds" do
      array =
        {:ok,
         Jason.encode!([
           %{"topic" => "killing", "condition" => "cornered with no way out"},
           %{"topic" => "lying", "condition" => "to protect someone she loves"}
         ])}

      existing = [%Polyphony.Authoring.CharacterSheet.Boundary{topic: "killing", stance: :closed}]

      assert {:ok, [%{"topic" => "lying"}]} =
               Autofill.suggest_boundaries(%{"name" => "Mira"},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array,
                 existing: existing
               )
    end
  end

  describe "suggest_relationships/2" do
    test "returns target/descriptor suggestions" do
      assert {:ok, suggestions} =
               Autofill.suggest_relationships(%{"name" => "Mira", "premise" => "a smuggler"},
                 provider: Polyphony.LLM.Mock
               )

      assert is_list(suggestions) and suggestions != []
      assert Enum.all?(suggestions, &(is_binary(&1["target"]) and &1["target"] != ""))
    end

    test "excludes people the character already has, and lists them in the prompt" do
      array =
        {:ok,
         Jason.encode!([
           %{"target" => "Bram", "descriptor" => "mentor"},
           %{"target" => "Vane", "descriptor" => "rival"}
         ])}

      existing = [%{"target" => "Bram", "descriptor" => "old mentor"}]

      assert {:ok, [%{"target" => "Vane"}]} =
               Autofill.suggest_relationships(%{"name" => "Mira"},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array,
                 existing: existing
               )
    end

    test "the existing relationships are shown to the model" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.suggest_relationships(%{"name" => "Mira"},
            provider: Polyphony.LLM.Stub,
            respond_with: capture,
            existing: [%{"target" => "Bram", "descriptor" => "old mentor"}]
          )
        end)

      assert msgs =~ "Bram"
      assert msgs =~ "old mentor"
      assert msgs =~ "do NOT propose"
    end

    test "does not propose the character themselves" do
      array =
        {:ok, Jason.encode!([%{"target" => "Mira", "descriptor" => "me"}, %{"target" => "Vane"}])}

      assert {:ok, [%{"target" => "Vane"}]} =
               Autofill.suggest_relationships(%{"name" => "Mira"},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )
    end

    test "de-duplicates repeated targets within one suggestion set" do
      array =
        {:ok,
         Jason.encode!([%{"target" => "Vane"}, %{"target" => "vane", "descriptor" => "dup"}])}

      assert {:ok, [%{"target" => "Vane"}]} =
               Autofill.suggest_relationships(%{},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )
    end

    test "parses a fenced JSON array and drops entries without a target" do
      array =
        {:ok,
         "```json\n" <>
           Jason.encode!([
             %{"target" => "Bram", "descriptor" => "mentor"},
             %{"descriptor" => "no target here"}
           ]) <> "\n```"}

      assert {:ok, [%{"target" => "Bram", "descriptor" => "mentor"}]} =
               Autofill.suggest_relationships(%{},
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )
    end
  end

  describe "extract_mentions/2" do
    test "returns the de-duped names from a JSON array" do
      array = {:ok, Jason.encode!(["Bram", "Vane", "bram"])}

      assert {:ok, names} =
               Autofill.extract_mentions(["Bram waved at Vane."],
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )

      assert names == ["Bram", "Vane"]
    end

    test "empty prose short-circuits without a provider call" do
      boom = fn _ -> raise "should not be called" end

      assert {:ok, []} =
               Autofill.extract_mentions(["", nil],
                 provider: Polyphony.LLM.Stub,
                 respond_with: boom
               )
    end
  end

  describe "reciprocal_roles/3" do
    test "maps each target to its generated reciprocal, in order" do
      array = {:ok, Jason.encode!(["former student", "wary creditor"])}

      pairs = [
        %{"target" => "Bram", "descriptor" => "estranged mentor"},
        %{"target" => "Vane", "descriptor" => "debtor"}
      ]

      assert {:ok, %{"Bram" => "former student", "Vane" => "wary creditor"}} =
               Autofill.reciprocal_roles(%{"name" => "Mira"}, pairs,
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )
    end

    test "an empty pair list short-circuits without a provider call" do
      # A provider that would crash if called proves it isn't.
      boom = fn _ -> raise "should not be called" end

      assert {:ok, %{}} =
               Autofill.reciprocal_roles(%{"name" => "Mira"}, [],
                 provider: Polyphony.LLM.Stub,
                 respond_with: boom
               )
    end

    test "the prompt states each source→target regard and asks for the reverse" do
      msgs =
        capture_prompt(fn capture ->
          Autofill.reciprocal_roles(
            %{"name" => "Mira"},
            [%{"target" => "Bram", "descriptor" => "estranged mentor"}],
            provider: Polyphony.LLM.Stub,
            respond_with: capture
          )
        end)

      assert msgs =~ "Mira regards Bram as \"estranged mentor\""
      assert msgs =~ "reciprocal"
    end

    test "skips blanks and tolerates a short/long array (zips by position)" do
      # Two pairs, one blank reciprocal and an extra ignored element.
      array = {:ok, Jason.encode!(["", "rival", "leftover"])}

      pairs = [
        %{"target" => "Bram", "descriptor" => "mentor"},
        %{"target" => "Vane", "descriptor" => "foe"}
      ]

      assert {:ok, %{"Vane" => "rival"} = map} =
               Autofill.reciprocal_roles(%{}, pairs,
                 provider: Polyphony.LLM.Stub,
                 respond_with: array
               )

      refute Map.has_key?(map, "Bram")
    end
  end

  describe "generate_field/4" do
    test "returns a single non-empty string for a known field" do
      current = %{"name" => "Mara", "temperament" => "guarded"}
      assert {:ok, value} = Autofill.generate_field(:character, "voice", current, @mock)
      assert is_binary(value) and value != ""
    end

    test "accepts an atom field name" do
      assert {:ok, _} = Autofill.generate_field(:character, :backstory, %{}, @mock)
    end

    test "rejects a field that isn't part of the kind" do
      assert {:error, {:unknown_field, "nope"}} =
               Autofill.generate_field(:character, "nope", %{}, @mock)
    end

    test "normalizes a list-typed field to newline-joined lines" do
      opts = [
        provider: Polyphony.LLM.Stub,
        respond_with: {:ok, "  gravity is weak \n\n time loops  "}
      ]

      assert {:ok, "gravity is weak\ntime loops"} =
               Autofill.generate_field(:world_bible, "rules", %{}, opts)
    end
  end

  describe "generate_scene_premise/1 (§2.3)" do
    test "returns a trimmed one-paragraph scene premise" do
      assert {:ok, "The tide turns at the jetty."} =
               Autofill.generate_scene_premise(
                 world: %{"name" => "Duskhaven"},
                 cast: [%{"name" => "Mira", "premise" => "a tidewarden"}],
                 provider: Polyphony.LLM.Stub,
                 respond_with: {:ok, "  The tide turns at the jetty.\n"}
               )
    end

    test "grounds the prompt in world, cast, setting, campaign premise, and the story so far" do
      msgs =
        capture_prompt(fn cap ->
          Autofill.generate_scene_premise(
            world: %{"name" => "Duskhaven", "setting" => "a drowned city"},
            cast: [%{"name" => "Mira", "premise" => "a tidewarden"}],
            location: "the eastern jetty",
            campaign_premise: "a long feud over the tideworks",
            recent: ["The gate was breached last night."],
            provider: Polyphony.LLM.Stub,
            respond_with: cap
          )
        end)

      assert msgs =~ "Duskhaven"
      assert msgs =~ "Mira — a tidewarden"
      assert msgs =~ "Location: the eastern jetty"
      assert msgs =~ "a long feud over the tideworks"
      assert msgs =~ "The gate was breached last night."
      # It's a scene premise, not the whole campaign.
      assert msgs =~ "scene premise" or msgs =~ "scene"
    end

    test "with a current premise it deepens rather than replaces (✨ Expand)" do
      msgs =
        capture_prompt(fn cap ->
          Autofill.generate_scene_premise(
            world: %{"name" => "Duskhaven"},
            current: "They meet at dawn.",
            provider: Polyphony.LLM.Stub,
            respond_with: cap
          )
        end)

      assert msgs =~ "The scene premise so far:"
      assert msgs =~ "They meet at dawn."
      assert msgs =~ "Deepen and sharpen"
    end
  end
end
