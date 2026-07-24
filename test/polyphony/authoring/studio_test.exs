defmodule Polyphony.Authoring.StudioTest do
  @moduledoc "Field-level character authoring (§15): review gate, convergence, metadata separation."
  use ExUnit.Case, async: true

  alias Polyphony.Repo
  alias Polyphony.Authoring.{Studio, FieldStore, DraftSchema, CharacterSheet}
  alias Polyphony.LLM.{Mock, Stub}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp generate(subject) do
    {:ok, _} =
      Studio.generate_sheet(subject, "a guarded envoy from the north", provider: Mock, repo: Repo)
  end

  # A spy provider capturing the regen prompt; returns a fixed field value.
  defp spy_regen(subject, field, value \\ "regenerated value") do
    spy = fn messages ->
      send(self(), {:prompt, messages})
      {:ok, value}
    end

    {:ok, row} =
      Studio.regenerate_field(subject, field, provider: Stub, respond_with: spy, repo: Repo)

    assert_received {:prompt, [_system, %{content: prompt}]}
    {row, prompt}
  end

  test "generating a sheet stores every field as a draft with provenance" do
    generate("c1")
    rows = FieldStore.list(Repo, "c1")

    assert length(rows) == 5
    assert Enum.all?(rows, &(&1.status == "draft"))
    assert Enum.all?(rows, &(&1.prompt_hash != nil))
  end

  test "regenerating a field updates only that field" do
    generate("c2")
    before = FieldStore.get(Repo, "c2", "temperament").value

    {:ok, _} = Studio.regenerate_field("c2", "voice", provider: Mock, repo: Repo)

    assert FieldStore.get(Repo, "c2", "temperament").value == before
    assert FieldStore.get(Repo, "c2", "voice").status == "draft"
  end

  describe "the review gate" do
    test "a locked field is never regenerated" do
      generate("c3")
      {:ok, _} = Studio.lock_field("c3", "voice", repo: Repo)
      locked = FieldStore.get(Repo, "c3", "voice").value

      assert {:error, :locked} =
               Studio.regenerate_field("c3", "voice", provider: Mock, repo: Repo)

      assert FieldStore.get(Repo, "c3", "voice").value == locked
    end

    test "accept and lock transition status" do
      generate("c4")
      {:ok, _} = Studio.accept_field("c4", "premise", repo: Repo)
      assert FieldStore.get(Repo, "c4", "premise").status == "accepted"

      {:ok, _} = Studio.lock_field("c4", "premise", repo: Repo)
      assert FieldStore.get(Repo, "c4", "premise").status == "locked"
    end
  end

  describe "convergence — accepted/locked fields are context" do
    test "a locked field's value guides regeneration of another field" do
      generate("c5")
      FieldStore.put(Repo, "c5", "voice", "gruff, clipped soldier-speak")
      {:ok, _} = Studio.lock_field("c5", "voice", repo: Repo)

      {_row, prompt} = spy_regen("c5", "backstory")
      assert prompt =~ "gruff, clipped soldier-speak"
    end
  end

  describe "metadata separation (§15)" do
    test "the generation schema is content-only — no workflow metadata" do
      assert DraftSchema.fields() == [:premise, :appearance, :voice, :temperament, :backstory]
    end

    test "the regen prompt carries values and feedback, never status/lock/provenance" do
      generate("c6")
      {_row, prompt} = spy_regen("c6", "voice")

      refute prompt =~ "status"
      refute prompt =~ "prompt_hash"
      refute prompt =~ "locked"
    end
  end

  test "feedback accumulates and lands in the next regen prompt" do
    generate("c7")
    {:ok, _} = Studio.add_feedback("c7", "voice", "make it warmer and wrier", repo: Repo)

    {_row, prompt} = spy_regen("c7", "voice")
    assert prompt =~ "make it warmer and wrier"
  end

  test "to_sheet folds the stored fields into a CharacterSheet" do
    generate("c8")
    sheet = Studio.to_sheet("c8", name: "Mira", repo: Repo)

    assert %CharacterSheet{name: "Mira"} = sheet
    assert is_binary(sheet.voice)
    assert is_binary(sheet.premise)
  end
end
