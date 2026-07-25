defmodule Polyphony.Authoring.StubTest do
  @moduledoc """
  §B8: character stubs. A stub is name + role + inbound relationships, no sheet.
  Promotion generates a full sheet behind a review gate (`:proposed`); only an
  accepted `:full` character is usable. Casting a stub prompts promotion (§B7).
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

  test "promotion generates a full sheet but gates it :proposed (not usable yet)" do
    stub = Stub.new("Ash", "a wary informant")

    gen = fn _stub, _opts ->
      {:ok, %{premise: "A cornered informant.", voice: "clipped", backstory: "Ran the docks."}}
    end

    assert {:ok, promoted} = Stub.promote(stub, generator: gen)
    assert promoted.status == :proposed
    assert promoted.premise == "A cornered informant."
    assert promoted.name == "Ash"
    # Still not usable until accepted.
    refute Stub.full?(promoted)
  end

  test "accept flips a :proposed sheet to :full" do
    stub = Stub.new("Ash", "role")
    {:ok, promoted} = Stub.promote(stub, generator: fn _s, _o -> {:ok, %{premise: "x"}} end)
    accepted = Stub.accept(promoted)
    assert accepted.status == :full
    assert Stub.full?(accepted)
  end

  test "a generation failure surfaces as an error, leaving nothing usable" do
    stub = Stub.new("Ash", "role")
    assert {:error, :boom} = Stub.promote(stub, generator: fn _s, _o -> {:error, :boom} end)
  end

  test "the default generator runs offline via the Mock provider" do
    stub = Stub.new("Ash", "a wary informant")
    assert {:ok, promoted} = Stub.promote(stub, provider: Polyphony.LLM.Mock)
    assert promoted.status == :proposed
    assert is_binary(promoted.premise)
  end

  describe "casting reflects promotion state (§B7)" do
    test "a stub and a proposed character are refused; a full one is allowed" do
      assert {:error, :stub_needs_promotion} =
               SceneControl.add_character("s", "ash", 1, status: :stub)

      assert {:error, :needs_promotion} =
               SceneControl.add_character("s", "ash", 1, status: :proposed)
    end
  end
end
