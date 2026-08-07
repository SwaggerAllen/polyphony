defmodule Polyphony.AudienceTest do
  @moduledoc """
  *Who starts out knowing this?* — `ux/polyphony-audience-picker.html`, end to end.

  The picker is only worth building if the answer reaches the prompt, so most of what
  is pinned here is the consumption rather than the control. A secret whose audience
  names Sable has to actually turn up in Sable's context, and stay out of everyone
  else's, or the whole component is a form that changes nothing.

  The rules it encodes, each a test:

    * **Nobody, by default.** Same default-deny as everything else, and the reading a
      pre-audience payload gets.
    * **Additive only.** No exceptions — a group plus named people, unioned.
    * **Groups are named, not expanded.** Resolution is live, which is what makes a
      walk-on written into the Tidewatch in scene 9 arrive already knowing.
    * **A character always knows their own secrets.** Never a decision.
    * **It only sets the starting point.** Everything after t=0 is play.

  "Everyone" is deliberately absent: it is the item's `concealed: false` state, not a
  stored audience. Two representations of one idea is how they drift apart.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Context, Groups, Library, Repo}
  alias Polyphony.Authoring.Knowledge
  alias Polyphony.Owner
  alias Polyphony.Authoring.{Audience, CharacterSheet, Group, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.Authoring.WorldBible.Entry

  @bell "The tide bell answers to something under the flats, and it is owed."
  @kestrel "Wren has been signing for the Kestrel's cargo since March."

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp character(owner, name),
    do: Library.put(%{owner: owner, kind: "character", payload: %CharacterSheet{name: name}})

  defp tidewatch(owner), do: Groups.create(owner, %Group{name: "The Tidewatch"})

  defp prefix(sheet, character_id, opts \\ []) do
    Context.materialize(
      Map.merge(
        %{scene_id: "S1", character_id: character_id, sheet: sheet},
        Map.new(opts)
      )
    ).prefix
  end

  describe "the default" do
    test "nobody, and a payload written before audiences existed reads the same way" do
      assert Audience.empty?(Audience.empty())
      assert Knowledge.resolve(nil) == []
      refute Knowledge.knows?(nil, "anyone")
      assert Audience.summary(nil) == "nobody knows"
    end
  end

  describe "resolution" do
    test "unions named people with every current member of every named group" do
      owner = owner()
      group = tidewatch(owner)
      sable = character(owner, "Sable Quist")
      bellman = character(owner, "The bellman")
      corrigan = character(owner, "Mother Corrigan")

      {:ok, _} = Groups.add_member(group.id, sable.id)
      {:ok, _} = Groups.add_member(group.id, bellman.id)

      audience =
        Audience.empty()
        |> Audience.add_group(group.id)
        |> Audience.add_character(corrigan.id)

      resolved = Knowledge.resolve(audience)

      assert Enum.sort(resolved) ==
               Enum.sort(Enum.map([sable.id, bellman.id, corrigan.id], &to_string/1))
    end

    test "a group is named, not expanded — its membership moving moves the audience" do
      owner = owner()
      group = tidewatch(owner)
      sable = character(owner, "Sable Quist")
      audience = Audience.add_group(Audience.empty(), group.id)

      refute Knowledge.knows?(audience, sable.id)

      # The load-bearing one: written into the Tidewatch later, and now they know.
      {:ok, _} = Groups.add_member(group.id, sable.id)
      assert Knowledge.knows?(audience, sable.id)

      {:ok, _} = Groups.remove_member(group.id, sable.id)
      refute Knowledge.knows?(audience, sable.id)
    end

    test "an empty group is not an error — it's how you set a trap first" do
      owner = owner()
      audience = Audience.add_group(Audience.empty(), tidewatch(owner).id)

      refute Audience.empty?(audience)
      assert Knowledge.resolve(audience) == []
    end

    test "the owner always knows, whether or not anyone ticked them" do
      assert Knowledge.knows?(Audience.empty(), "wren", owner: "wren")
      assert "wren" in Knowledge.resolve(nil, owner: "wren")
    end

    test "nobody is named twice, however many ways they got in" do
      owner = owner()
      group = tidewatch(owner)
      sable = character(owner, "Sable Quist")
      {:ok, _} = Groups.add_member(group.id, sable.id)

      audience =
        Audience.empty() |> Audience.add_group(group.id) |> Audience.add_character(sable.id)

      assert Knowledge.resolve(audience, owner: sable.id) == [to_string(sable.id)]
    end
  end

  describe "editing an audience" do
    test "adds are idempotent and order-preserving" do
      a =
        Audience.empty()
        |> Audience.add_character("a")
        |> Audience.add_character("b")
        |> Audience.add_character("a")

      assert a.character_ids == ["a", "b"]
    end

    test "toggling a group off takes everyone who was only in it by inheritance" do
      owner = owner()
      group = tidewatch(owner)
      sable = character(owner, "Sable Quist")
      {:ok, _} = Groups.add_member(group.id, sable.id)

      a = Audience.toggle_group(Audience.empty(), group.id)
      assert Knowledge.knows?(a, sable.id)

      a = Audience.toggle_group(a, group.id)
      refute Knowledge.knows?(a, sable.id)
    end

    test "named/1 separates a solid tick from an inherited one" do
      owner = owner()
      group = tidewatch(owner)
      sable = character(owner, "Sable Quist")
      {:ok, _} = Groups.add_member(group.id, sable.id)

      inherited = Audience.add_group(Audience.empty(), group.id)
      assert Audience.named(inherited) == []
      assert Knowledge.knows?(inherited, sable.id)

      # There is no way to un-tick an inherited one, which is what "no exceptions" costs.
      assert Audience.remove_character(inherited, sable.id) == inherited
    end
  end

  describe "the item's own line" do
    test "reads as the design writes it" do
      names = fn id -> %{"g1" => "the Tidewatch", "c1" => "Aldous", "c2" => "Sable"}[id] end

      assert Audience.summary(Audience.empty(), names) == "nobody knows"
      assert Audience.summary(%Audience{character_ids: ["c1"]}, names) == "Aldous knows"

      assert Audience.summary(%Audience{character_ids: ["c1", "c2"]}, names) ==
               "Aldous, Sable know"

      assert Audience.summary(%Audience{group_ids: ["g1"], character_ids: ["c1"]}, names) ==
               "the Tidewatch, Aldous know"

      assert Audience.summary(
               %Audience{group_ids: ["g1"], character_ids: ["c1", "c2"]},
               names
             ) == "the Tidewatch, Aldous, +1"
    end
  end

  describe "a world secret reaching the people it names" do
    test "is in their prefix, and in nobody else's" do
      owner = owner()
      group = tidewatch(owner)
      sable = character(owner, "Sable Quist")
      wren = character(owner, "Wren Ashgrove")
      {:ok, _} = Groups.add_member(group.id, sable.id)

      bible = %WorldBible{
        name: "Saltmarch",
        starting_canon: [
          %Entry{statement: "The Kestrel docked twice this month."},
          %Entry{
            statement: @bell,
            concealed: true,
            audience: Audience.add_group(Audience.empty(), group.id)
          }
        ]
      }

      insider = prefix(%CharacterSheet{name: "Sable"}, sable.id, world_bible: bible)
      outsider = prefix(%CharacterSheet{name: "Wren"}, wren.id, world_bible: bible)

      assert insider =~ @bell
      refute outsider =~ @bell
      # The public entry reaches both, which is what makes the difference legible.
      assert insider =~ "The Kestrel docked twice this month."
      assert outsider =~ "The Kestrel docked twice this month."
    end

    test "a stranger sees no secret at all — default-deny, and §3.2's unassigned viewer" do
      bible = %WorldBible{starting_canon: [%Entry{statement: @bell, concealed: true}]}

      assert WorldBible.statements(Knowledge.for_character(bible).starting_canon) == []
      assert Knowledge.known_to(bible.starting_canon, nil) == []
    end
  end

  describe "one character's secret reaching another" do
    test "arrives named, so it reads as being about them rather than about you" do
      owner = owner()
      sable = character(owner, "Sable Quist")

      wren_sheet = %CharacterSheet{
        name: "Wren Ashgrove",
        facts: [
          %Fact{
            statement: @kestrel,
            concealed: true,
            audience: Audience.add_character(Audience.empty(), sable.id)
          }
        ]
      }

      cast = [{"wren", wren_sheet}, {to_string(sable.id), %CharacterSheet{name: "Sable Quist"}}]

      text = prefix(%CharacterSheet{name: "Sable Quist"}, to_string(sable.id), cast: cast)

      assert text =~ "Wren Ashgrove: #{@kestrel}"
      assert text =~ "You also know, and are not supposed to"
    end

    test "reaches nobody the audience doesn't name" do
      owner = owner()
      sable = character(owner, "Sable Quist")

      wren_sheet = %CharacterSheet{
        name: "Wren Ashgrove",
        facts: [%Fact{statement: @kestrel, concealed: true}]
      }

      cast = [{"wren", wren_sheet}]
      text = prefix(%CharacterSheet{name: "Sable Quist"}, to_string(sable.id), cast: cast)

      refute text =~ @kestrel
    end

    test "a character's own secret comes through their sheet, not through this" do
      wren_sheet = %CharacterSheet{
        name: "Wren Ashgrove",
        facts: [%Fact{statement: @kestrel, concealed: true, core: true}]
      }

      text = prefix(wren_sheet, "wren", cast: [{"wren", wren_sheet}])

      # Once — from her own always-resident facts, not doubled by the shared block.
      assert text =~ @kestrel
      refute text =~ "You also know, and are not supposed to"
    end

    test "a caller that supplies no cast makes a character know too little, never too much" do
      owner = owner()
      sable = character(owner, "Sable Quist")

      wren_sheet = %CharacterSheet{
        name: "Wren",
        facts: [
          %Fact{
            statement: @kestrel,
            concealed: true,
            audience: Audience.add_character(Audience.empty(), sable.id)
          }
        ]
      }

      # Nothing passed: default-deny rather than a crash or a leak.
      refute prefix(%CharacterSheet{name: "Sable"}, to_string(sable.id)) =~ @kestrel

      assert prefix(%CharacterSheet{name: "Sable"}, to_string(sable.id),
               cast: [{"w", wren_sheet}]
             ) =~
               @kestrel
    end
  end

  describe "the Director" do
    test "still sees everything — it isn't a member of any audience, it's omniscient" do
      bible = %WorldBible{
        name: "Saltmarch",
        starting_canon: [%Entry{statement: @bell, concealed: true}]
      }

      brief = Polyphony.Director.SceneBrief.materialize("S1", world_bible: bible).prefix
      assert brief =~ @bell
    end
  end
end
