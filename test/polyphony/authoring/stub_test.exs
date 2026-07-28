defmodule Polyphony.Authoring.StubTest do
  @moduledoc """
  §B8: character stubs. A stub is name + role + inbound relationships, no sheet — it
  reads as *pending* until an author opens it and saves (which finalizes it to
  `:full` in the editor). A pending stub is not castable (§B7).
  """
  use ExUnit.Case, async: true

  alias Polyphony.Authoring.Stub
  alias Polyphony.Authoring.CharacterSheet.Relationship
  alias Polyphony.SceneControl

  test "new/3 builds a stub with no generated sheet" do
    stub =
      Stub.new("Ash", "a wary informant",
        relationships: [%Relationship{target: "mira", descriptor: "owes a debt"}]
      )

    assert Stub.stub?(stub)
    refute Stub.full?(stub)
    assert stub.premise == nil and stub.voice == nil
    assert stub.role == "a wary informant"
  end

  describe "casting reflects finalization state (§B7)" do
    test "a pending (stub or proposed) character is refused; a full one is allowed" do
      assert {:error, :stub_needs_promotion} =
               SceneControl.add_character("s", "ash", 1, status: :stub)

      assert {:error, :needs_promotion} =
               SceneControl.add_character("s", "ash", 1, status: :proposed)
    end
  end
end
