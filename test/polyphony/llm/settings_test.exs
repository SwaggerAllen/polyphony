defmodule Polyphony.LLM.SettingsTest do
  @moduledoc "Per-campaign LLM tuning resolution + coercion (§9)."
  use ExUnit.Case, async: true

  alias Polyphony.LLM.Settings

  test "defaults: Director thinking off, generous Director budget" do
    assert %{director_thinking: false, director_max_tokens: 2048, character_max_tokens: 1024} =
             Settings.defaults()
  end

  test "from_payload merges campaign overrides over the defaults" do
    payload = %{llm: %{director_thinking: true, director_max_tokens: 4096}}
    settings = Settings.from_payload(payload)

    assert settings.director_thinking == true
    assert settings.director_max_tokens == 4096
    # Unset key falls back to the default.
    assert settings.character_max_tokens == 1024
  end

  test "coerces string values (as forms store them) to the right types" do
    payload = %{"llm" => %{"director_thinking" => "true", "director_max_tokens" => "3000"}}
    settings = Settings.from_payload(payload)

    assert settings.director_thinking == true
    assert settings.director_max_tokens == 3000
  end

  test "a payload with no llm section is all defaults" do
    assert Settings.from_payload(%{name: "x"}) == Settings.defaults()
  end

  test "a bad token value falls back to the default rather than breaking" do
    settings = Settings.from_payload(%{llm: %{director_max_tokens: "not-a-number"}})
    assert settings.director_max_tokens == 2048
  end
end
