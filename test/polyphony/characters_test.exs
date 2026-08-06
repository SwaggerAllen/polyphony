defmodule Polyphony.CharactersTest do
  @moduledoc """
  Cast tiers (`completed-roadmap.md` §2.5) — the second axis, and the operations that
  move a character along it.

  The thing worth pinning is that `tier` and `status` stay independent. They came
  apart because *no character ever plays without a full sheet*: once the walk-on the
  Director admits gets a generated sheet like anyone else, `status` can no longer
  tell the bellman from the lead, and something has to. So promoting a walk-on must
  not touch whether their sheet is written, and writing a sheet must not promote
  anyone.

  Demotion is tested as carefully as promotion, deliberately: the design's whole
  point is that a character who has served their purpose is **demoted rather than
  deleted**, and a demote that quietly failed would push authors back to deleting.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Characters, Library, Owner, Repo}
  alias Polyphony.Authoring.CharacterSheet

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp write(owner, name, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name}, attrs)
    Library.put(%{owner: owner, kind: "character", payload: sheet}, [])
  end

  defp tier(id), do: Characters.get(id).tier

  describe "tiers on the sheet" do
    test "a new character is main cast until someone says otherwise" do
      owner = owner()
      assert %CharacterSheet{tier: :main} = Characters.get(write(owner, "Wren").id)
    end

    test "residency is the point of the axis: only walk-ons fall out of context" do
      assert CharacterSheet.resident?(:main)
      assert CharacterSheet.resident?(:recurring)
      refute CharacterSheet.resident?(:incidental)
    end
  end

  describe "promote/demote" do
    test "a walk-on who turns out to matter climbs, one tier at a time" do
      owner = owner()
      bellman = write(owner, "The bellman", %{tier: :incidental})

      assert {:ok, _} = Characters.promote(bellman.id)
      assert tier(bellman.id) == :recurring

      assert {:ok, _} = Characters.promote(bellman.id)
      assert tier(bellman.id) == :main
    end

    test "a character who has served their purpose is demoted, not deleted" do
      owner = owner()
      wren = write(owner, "Wren")

      assert {:ok, _} = Characters.demote(wren.id)
      assert tier(wren.id) == :recurring

      assert {:ok, _} = Characters.demote(wren.id)
      assert tier(wren.id) == :incidental

      # Still there, still readable — that's the whole difference from deleting.
      assert %CharacterSheet{name: "Wren"} = Characters.get(wren.id)
    end

    test "both directions saturate rather than run off the end" do
      owner = owner()
      lead = write(owner, "Wren")
      walk_on = write(owner, "A porter", %{tier: :incidental})

      assert {:ok, _} = Characters.promote(lead.id)
      assert tier(lead.id) == :main

      assert {:ok, _} = Characters.demote(walk_on.id)
      assert tier(walk_on.id) == :incidental
    end

    test "tiering does not touch whether the sheet is written" do
      owner = owner()
      stub = write(owner, "A face in the crowd", %{status: :stub, tier: :incidental})

      assert {:ok, _} = Characters.promote(stub.id)
      assert %CharacterSheet{tier: :recurring, status: :stub} = Characters.get(stub.id)
    end

    test "set_tier refuses a tier that isn't one" do
      owner = owner()
      wren = write(owner, "Wren")

      assert {:error, {:unknown_tier, :protagonist}} = Characters.set_tier(wren.id, :protagonist)
      assert tier(wren.id) == :main
    end

    test "moving someone who isn't a character is an error, not a new character" do
      missing = 2_147_483_000
      assert {:error, :not_found} = Characters.promote(missing)
      assert {:error, :not_found} = Characters.set_tier(missing, :main)
    end
  end

  describe "by_tier/1" do
    test "groups the cast into the list's sections, most resident first" do
      owner = owner()
      write(owner, "The porter", %{tier: :incidental})
      write(owner, "Wren")
      write(owner, "Halloran", %{tier: :recurring})

      assert [
               {:main, "Main cast", [wren]},
               {:recurring, "Recurring", [halloran]},
               {:incidental, "Walk-ons", [porter]}
             ] = owner |> Characters.list() |> Characters.by_tier()

      assert Characters.get(wren.id).name == "Wren"
      assert Characters.get(halloran.id).name == "Halloran"
      assert Characters.get(porter.id).name == "The porter"
    end

    test "an empty tier gets no heading" do
      owner = owner()
      write(owner, "Wren")

      assert [{:main, "Main cast", [_]}] = owner |> Characters.list() |> Characters.by_tier()
    end

    test "order within a section survives the grouping" do
      owner = owner()
      first = write(owner, "First")
      second = write(owner, "Second")

      entries = [second, first]
      assert [{:main, _, [a, b]}] = Characters.by_tier(entries)
      assert [a.id, b.id] == [second.id, first.id]
    end
  end

  describe "resident/1" do
    test "keeps main and recurring, drops walk-ons" do
      owner = owner()
      write(owner, "Wren")
      write(owner, "Halloran", %{tier: :recurring})
      write(owner, "The porter", %{tier: :incidental})

      names =
        owner
        |> Characters.list()
        |> Characters.resident()
        |> Enum.map(&Characters.get(&1.id).name)
        |> Enum.sort()

      assert names == ["Halloran", "Wren"]
    end
  end
end
