defmodule Polyphony.LLM.DeepInfraBodyTest do
  @moduledoc "The request body's JSON-mode / thinking / token wiring (§2, §3)."
  use ExUnit.Case, async: true

  alias Polyphony.LLM.DeepInfra

  @cfg [model: "test-model"]
  @messages [%{role: "user", content: "hi"}]

  test "a structured call (:response set) forces OpenAI JSON mode" do
    body = DeepInfra.build_body(@messages, [response: :decision], @cfg)
    assert body.response_format == %{type: "json_object"}
  end

  test "a plain prose call leaves the response unconstrained" do
    body = DeepInfra.build_body(@messages, [], @cfg)
    refute Map.has_key?(body, :response_format)
  end

  test "thinking is disabled via the chat-template kwarg unless explicitly on" do
    off = DeepInfra.build_body(@messages, [], @cfg)
    assert off.chat_template_kwargs == %{enable_thinking: false}

    on = DeepInfra.build_body(@messages, [thinking: true], @cfg)
    refute Map.has_key?(on, :chat_template_kwargs)
  end

  test "max_tokens and model come from opts/cfg" do
    body = DeepInfra.build_body(@messages, [max_tokens: 3000], @cfg)
    assert body.max_tokens == 3000
    assert body.model == "test-model"
  end
end
