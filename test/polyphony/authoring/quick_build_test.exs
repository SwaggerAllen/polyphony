defmodule Polyphony.Authoring.QuickBuildTest do
  @moduledoc """
  Quick Build scaffolds a whole campaign from seeds: a world bible, one character per
  seed line (grounded in the world, cross-linked), and a premise — all persisted to the
  author's library. Driven by the offline Mock so generation is deterministic.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Library, Owner, Repo}
  alias Polyphony.Authoring.{CharacterSheet, QuickBuild, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Boundary

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
      # Boundaries are generated too (same as the editor's "Generate all fields"), and
      # every generated one is a conditional slow-burn with a real condition.
      assert sheet.boundaries != []

      assert Enum.all?(
               sheet.boundaries,
               &match?(%Boundary{stance: :conditional, condition: c} when c not in [nil, ""], &1)
             )
    end

    # Cross-linked: each character regards the other, by stable id AND with a role
    # (a non-empty descriptor) — not a bare, role-less link.
    [a, b] = result.characters
    sheet_a = Library.payload(a)
    assert [rel] = sheet_a.relationships
    assert rel.target_id == b.id
    assert rel.descriptor not in [nil, ""]

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

  defmodule OneBadProvider do
    @moduledoc "Mock, except a character brief containing BOOMCHAR generates blank (a failure)."
    @behaviour Polyphony.LLM.Provider

    @impl true
    def complete(messages, opts) do
      # Only the character's OWN seed counts — not another character named in the
      # ensemble-context roster (which is appended after "Ensemble context").
      primary =
        messages |> Enum.map_join(" ", & &1.content) |> String.split("Ensemble context") |> hd()

      if Keyword.get(opts, :response) == :autofill and String.contains?(primary, "BOOMCHAR") do
        {:ok, "{}"}
      else
        Polyphony.LLM.Mock.complete(messages, opts)
      end
    end
  end

  test "a single character failure keeps the world, the rest of the cast, and the premise",
       %{owner: owner} do
    {:ok, result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a harbor city",
        character_seeds: ["a good sailor", "BOOMCHAR the doomed"],
        provider: OneBadProvider
      )

    # The world, the one good character, and the premise survive.
    assert %WorldBible{} = Library.payload(result.bible)
    assert length(result.characters) == 1
    assert result.premise != ""

    # The failed seed is reported, not silently dropped.
    assert [{"BOOMCHAR the doomed", :blank_generation}] = result.failed
  end

  test "the build errors only when every character seed fails", %{owner: owner} do
    assert {:error, {:all_characters_failed, failed}} =
             QuickBuild.build(
               owner: owner,
               world_seed: "a harbor city",
               character_seeds: ["BOOMCHAR one", "BOOMCHAR two"],
               provider: OneBadProvider
             )

    assert length(failed) == 2
  end

  test "reports progress through each phase", %{owner: owner} do
    me = self()

    {:ok, _result} =
      QuickBuild.build(
        owner: owner,
        world_seed: "a harbor city",
        character_seeds: ["a sailor", "a fixer"],
        provider: Polyphony.LLM.Mock,
        progress: fn step -> send(me, {:progress, step}) end
      )

    steps = collect_progress([])

    # Total is world + 2 characters + linking + premise = 5, and the bar advances to full.
    assert Enum.all?(steps, &(&1.total == 5))
    assert List.last(steps).done == 5
    assert Enum.map(steps, & &1.done) == Enum.sort(Enum.map(steps, & &1.done))

    labels = Enum.map(steps, & &1.label)
    assert "Dreaming up the world" in labels
    assert "Writing character 1 of 2" in labels
    assert "Framing the premise" in labels
  end

  defp collect_progress(acc) do
    receive do
      {:progress, step} -> collect_progress([step | acc])
    after
      0 -> Enum.reverse(acc)
    end
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
