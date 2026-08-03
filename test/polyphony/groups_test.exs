defmodule Polyphony.GroupsTest do
  @moduledoc """
  Groups: character-shaped templates that seed people and hold secrets.

  The two jobs a group does are deliberately independent, and most of what's
  pinned here is that they stay that way.

  **Seeding is a copy.** Anyone written from a group starts with its fields and
  knows what it knows — and editing the template afterwards reaches nobody already
  written from it. That's what makes group arc a fan-out through review
  (`backend-backlog.md` §3.0b) rather than a silent propagation, which is the rule
  everywhere else in this system.

  **Membership is live, and joining doesn't backfill.** A secret pointed at the
  Tidewatch means whoever is in it when the question is asked. But if Wren joins in
  scene 9 she doesn't silently acquire what it knows — the design is explicit that
  the reveal is fiction, not a migration, the same principle as world-arc catch-up.
  That's the one a well-meaning "helpful" implementation would break.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Groups, Library, Owner, Repo}
  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Authoring.CharacterSheet.Fact

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp tidewatch(owner, extra \\ %{}) do
    group =
      struct(
        %Group{
          name: "The Tidewatch",
          premise: "They keep the bell, and the bell keeps something else.",
          temperament: "Watchful, and slow to say why.",
          facts: [
            %Fact{statement: "They ring for the tide, not for ships."},
            %Fact{statement: "The bell answers to something under the flats.", concealed: true}
          ]
        },
        extra
      )

    Groups.create(owner, group)
  end

  defp payload(entry), do: entry.id |> Library.get() |> Library.payload()

  describe "the group itself" do
    test "is a library entry, so it inherits ownership and the rest" do
      o = owner()
      entry = tidewatch(o)

      assert entry.kind == "group"
      assert %Group{name: "The Tidewatch"} = payload(entry)
      assert Enum.map(Groups.list(o), & &1.id) == [entry.id]
    end

    test "its secrets are the facts membership is what grants you" do
      assert [%Fact{concealed: true, statement: statement}] =
               Group.secrets(payload(tidewatch(owner())))

      assert statement =~ "under the flats"
    end
  end

  describe "membership" do
    test "is a live, ordered set keyed by library id" do
      o = owner()
      group = tidewatch(o)

      {:ok, _} = Groups.add_member(group.id, "11")
      {:ok, _} = Groups.add_member(group.id, "22")

      assert Groups.member_ids(group.id) == ["11", "22"]

      {:ok, _} = Groups.remove_member(group.id, "11")
      assert Groups.member_ids(group.id) == ["22"]
    end

    test "adding twice doesn't duplicate, and removing a stranger is a no-op" do
      o = owner()
      group = tidewatch(o)

      {:ok, _} = Groups.add_member(group.id, "11")
      {:ok, _} = Groups.add_member(group.id, "11")
      {:ok, _} = Groups.remove_member(group.id, "99")

      assert Groups.member_ids(group.id) == ["11"]
    end

    test "an empty group is a legitimate answer, not an error" do
      # The design's own point: empty groups are how you set a trap before anyone
      # walks into it.
      assert Groups.member_ids(tidewatch(owner()).id) == []
    end

    test "a character's groups are derived, so the two directions can't disagree" do
      o = owner()
      tide = tidewatch(o)
      office = Groups.create(o, %Group{name: "The harbour office"})

      {:ok, _} = Groups.add_member(tide.id, "11")
      {:ok, _} = Groups.add_member(office.id, "22")

      assert Enum.map(Groups.for_character(o, "11"), & &1.id) == [tide.id]
      assert Groups.for_character(o, "33") == []
    end

    test "editing a group's fields leaves its membership alone" do
      o = owner()
      group = tidewatch(o)
      {:ok, _} = Groups.add_member(group.id, "11")

      {:ok, _} = Groups.update_fields(group.id, %Group{name: "The Tidewatch", premise: "New."})

      assert Groups.member_ids(group.id) == ["11"]
      assert payload(group).premise == "New."
    end
  end

  describe "writing a character from a group" do
    test "seeds their sheet and joins them to it" do
      o = owner()
      group = tidewatch(o)

      {:ok, entry} = Groups.write_character(o, group.id, %CharacterSheet{name: "Sable Quist"})
      sheet = payload(entry)

      assert sheet.name == "Sable Quist"
      assert sheet.premise =~ "keep the bell"
      assert sheet.temperament =~ "Watchful"
      # Including the secret: knowing it is what belonging means.
      assert Enum.any?(sheet.facts, &(&1.concealed and &1.statement =~ "under the flats"))
      assert Groups.member_ids(group.id) == [to_string(entry.id)]
    end

    test "anything the author already wrote wins — a group is a starting point" do
      o = owner()
      group = tidewatch(o)

      {:ok, entry} =
        Groups.write_character(o, group.id, %CharacterSheet{
          name: "Sable Quist",
          premise: "She rings it for money and asks nothing."
        })

      assert payload(entry).premise == "She rings it for money and asks nothing."
    end

    test "editing the group afterwards reaches nobody already written from it" do
      # Seeding is a copy. This is what makes group arc a fan-out through review
      # (§3.0b) rather than a silent propagation — and silent propagation is the
      # thing this system doesn't do anywhere.
      o = owner()
      group = tidewatch(o)
      {:ok, entry} = Groups.write_character(o, group.id, %CharacterSheet{name: "Sable"})

      {:ok, _} =
        Groups.update_fields(group.id, %Group{
          name: "The Tidewatch",
          premise: "Rewritten entirely.",
          facts: [%Fact{statement: "A wholly new secret.", concealed: true}]
        })

      sheet = payload(entry)
      assert sheet.premise =~ "keep the bell"
      refute Enum.any?(sheet.facts, &(&1.statement =~ "wholly new"))
    end

    test "an unknown group is refused rather than half-writing a character" do
      assert Groups.write_character(owner(), 0, %CharacterSheet{name: "Nobody"}) ==
               {:error, :not_found}
    end
  end

  describe "joining doesn't backfill" do
    test "adding a member gives them nothing the group knows" do
      # If Wren joins the Tidewatch in scene 9 she doesn't silently gain its
      # secret — she learns it in a scene. The reveal is fiction, not a migration.
      o = owner()
      group = tidewatch(o)

      wren =
        Library.put(%{
          owner: o,
          kind: "character",
          payload: %CharacterSheet{name: "Wren", status: :full}
        })

      {:ok, _} = Groups.add_member(group.id, wren.id)

      assert payload(wren).facts == []
      assert payload(wren).premise == nil
      # She is a member all the same — an audience naming the group now includes her.
      assert to_string(wren.id) in Groups.member_ids(group.id)
    end
  end
end
