defmodule Polyphony.PronounsTest do
  @moduledoc """
  Pronouns are a field, and they reach the model.

  `ux/README.md` puts this under copy rules — *pronouns are a field* — but it isn't
  only a display concern, which is why it's tested here rather than in a view test.
  Every character prompt renders the sheet. With nothing to render, the model infers
  pronouns from a name: a guess, and a wrong guess lands *inside the fiction*, where
  it reads as the story being wrong about someone rather than as a setting nobody
  filled in.

  So what's pinned is the path: authored on the sheet, rendered into the character's
  own context, and offered by generation so a written character arrives with one.
  """
  use ExUnit.Case, async: true

  alias Polyphony.Context
  alias Polyphony.Authoring.{Autofill, CharacterSheet}

  defp prefix(sheet) do
    Context.materialize(scene_id: "pron-1", character_id: "1", sheet: sheet).prefix
  end

  test "reach the character's own prompt, next to their name" do
    rendered = prefix(%CharacterSheet{name: "Wren Ashgrove", pronouns: "she / her"})

    assert rendered =~ "she / her"
    # Immediately after the name: it governs every sentence written about them,
    # including the third-person prose the model writes for their actions.
    assert :binary.match(rendered, "Wren Ashgrove") < :binary.match(rendered, "she / her")
  end

  test "any pronouns at all, because the set isn't closed" do
    for p <- ["they / them", "he / him", "ey / em", "she / they"] do
      assert prefix(%CharacterSheet{name: "N", pronouns: p}) =~ p
    end
  end

  test "a sheet without them says nothing rather than guessing" do
    rendered = prefix(%CharacterSheet{name: "Wren Ashgrove"})

    refute rendered =~ "Referred to as"
  end

  test "generation is asked for them, and told not to infer from the name" do
    guidance =
      Autofill.fields(:character)
      |> Enum.find_value(fn {field, _type, guidance} -> field == "pronouns" && guidance end)

    assert guidance
    assert guidance =~ "don't assume from the name"
  end
end
