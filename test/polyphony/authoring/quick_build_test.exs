defmodule Polyphony.Authoring.QuickBuildTest do
  @moduledoc """
  Quick Build scaffolds a whole campaign from seeds: a world bible, one character per
  seed line (grounded in the world, cross-linked), and a premise — all persisted to the
  author's library. Driven by the offline Mock so generation is deterministic.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Owner, Repo}
  alias Polyphony.Authoring.{CharacterSheet, QuickBuild, WorldBible}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    %{owner: Owner.user("quick-build-#{System.unique_integer([:positive])}")}
  end

  test "builds a world, a cast, cross-links relationships, and a premise", %{owner: owner} do
    {:ok, result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a rain-drowned harbor city",
        character_seeds: ["a disgraced harbor-master", "the collector who bought her past"],
        provider: Polyphony.LLM.Mock
      )

    # A world bible, persisted and returned.
    assert %WorldBible{} = wb = Library.payload(result.bible)
    assert wb.name not in [nil, ""]
    assert Library.get(result.bible.id).kind == "world_bible"

    # One :full character per seed line, linked to the world.
    assert length(result.characters) == 2

    for entry <- result.characters do
      sheet = Library.payload(entry)
      assert %CharacterSheet{status: :full} = sheet
      assert sheet.world_bible_id == result.bible.id
      assert sheet.premise not in [nil, ""]
    end

    # Cross-linked: each character regards the other, by stable id (not just name).
    [a, b] = result.characters
    sheet_a = Library.payload(a)
    assert [rel] = sheet_a.relationships
    assert rel.target_id == b.id

    # A premise came back.
    assert is_binary(result.premise) and result.premise != ""
  end

  test "the whole cast lands in the owner's library", %{owner: owner} do
    before = Enum.count(Library.list_for_owner(owner))

    {:ok, _result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "neon arcology",
        character_seeds: ["a courier", "a fixer", "a ghost"],
        provider: Polyphony.LLM.Mock
      )

    entries = Library.list_for_owner(owner)
    # 1 world + 3 characters added.
    assert Enum.count(entries) == before + 4
    assert Enum.count(entries, &(&1.kind == "character")) == 3
    assert Enum.count(entries, &(&1.kind == "world_bible")) == 1
  end

  test "with off-screen suggestions on, each character stubs extra people", %{owner: owner} do
    {:ok, result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a rain-drowned harbor city",
        character_seeds: ["a disgraced harbor-master", "the collector who bought her past"],
        suggest_offscreen: true,
        provider: Polyphony.LLM.Mock
      )

    chars = Enum.filter(Library.list_for_owner(owner), &(&1.kind == "character"))
    stubs = Enum.filter(chars, &match?(%CharacterSheet{status: :stub}, Library.payload(&1)))

    # The two main cast plus stubbed off-screen people.
    assert length(chars) > 2
    assert stubs != []

    # Stubs are still off the campaign roster — only the main cast is returned.
    assert length(result.characters) == 2

    # Each stub is pending, linked to the world, and its inbound relationships all point
    # back at the main cast that introduced it.
    main_ids = Enum.map(result.characters, & &1.id)

    for stub <- stubs do
      sheet = Library.payload(stub)
      assert sheet.status == :stub
      assert sheet.world_bible_id == result.bible.id
      assert sheet.relationships != []
      assert Enum.all?(sheet.relationships, &(&1.target_id in main_ids))
    end

    # A main character links to at least one off-screen stub (target_id set to a stub).
    stub_ids = MapSet.new(stubs, & &1.id)
    main = Library.payload(hd(result.characters))
    assert Enum.any?(main.relationships, &(&1.target_id in stub_ids))
  end

  test "an off-screen person named by two characters collapses into one shared stub",
       %{owner: owner} do
    # Identical seeds ⇒ identical generated sheets ⇒ both characters propose the same
    # off-screen names (the Mock is deterministic in the prompt), so they must dedupe.
    {:ok, result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a walled city",
        character_seeds: ["a twin", "a twin"],
        suggest_offscreen: true,
        provider: Polyphony.LLM.Mock
      )

    chars = Enum.filter(Library.list_for_owner(owner), &(&1.kind == "character"))
    stubs = Enum.filter(chars, &match?(%CharacterSheet{status: :stub}, Library.payload(&1)))
    main_ids = Enum.sort(Enum.map(result.characters, & &1.id))

    # No duplicate stub names — the shared people were reused, not re-created.
    stub_names = Enum.map(stubs, &String.downcase(Library.payload(&1).name))
    assert stub_names == Enum.uniq(stub_names)

    # A shared stub links back to BOTH twins (one inbound relationship each).
    assert Enum.any?(stubs, fn stub ->
             ids = Library.payload(stub).relationships |> Enum.map(& &1.target_id) |> Enum.sort()
             ids == main_ids
           end)
  end

  test "off-screen suggestions are off by default (cast-only interlink)", %{owner: owner} do
    {:ok, _result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a quiet village",
        character_seeds: ["a baker", "a constable"],
        provider: Polyphony.LLM.Mock
      )

    chars = Enum.filter(Library.list_for_owner(owner), &(&1.kind == "character"))
    # Exactly the two main cast — no stubs.
    assert length(chars) == 2
    assert Enum.all?(chars, &match?(%CharacterSheet{status: :full}, Library.payload(&1)))
  end

  test "a blank character list still builds a world and premise", %{owner: owner} do
    {:ok, result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a quiet village",
        character_seeds: [],
        provider: Polyphony.LLM.Mock
      )

    assert result.characters == []
    assert %WorldBible{} = Library.payload(result.bible)
    assert result.premise != ""
  end
end
