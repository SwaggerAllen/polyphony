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
end
