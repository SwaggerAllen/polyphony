defmodule Polyphony.ArcReviewTest do
  @moduledoc """
  What the arc-review screen needs the domain to be able to say
  (`ux/polyphony-arc.html`).

  Four things, each a rule rather than a field:

    * **Every proposal says why.** The design's argument is that the *Because* line is
      what makes accepting quick — you can check the reasoning without going back and
      rereading — so a proposal that can't say why is one you have to earn twice.
    * **A line gave is its own kind.** `BoundaryGate` already resolved it scene-locally
      from canon; a `:release` is what makes it permanent, which is the distinction the
      design draws between play and review.
    * **World arc says who knows.** A character's arc is theirs; a world's is
      everyone's — so it carries an audience, and *everyone* versus *whoever was there*
      is the same picker doing the same job it does on a secret.
    * **Nothing propagates silently.** A group's change fans out into one proposal per
      member, which is what makes dissent free: say no once and you've written the
      person who didn't go along with it.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{Groups, Library, Owner, Repo}

  alias Polyphony.Authoring.{
    Audience,
    CharacterSheet,
    EffectiveSheet,
    EffectiveWorldBible,
    Group,
    GroupArc,
    WorldArcEntry,
    WorldBible
  }

  alias Polyphony.Authoring.ArcEntry, as: Arc
  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias Polyphony.ReadModels.ArcEntry
  alias Polyphony.SceneClose.{ArcSchema, WorldArcSchema}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp owner, do: Owner.coerce(System.unique_integer([:positive]))

  defp character(owner, name),
    do: Library.put(%{owner: owner, kind: "character", payload: %CharacterSheet{name: name}})

  describe "because" do
    test "an extracted proposal carries the reason through to the row" do
      data = %{
        "entries" => [
          %{
            "kind" => "discovery",
            "statement" => "She has stopped signing in her mother's hand.",
            "reason" => "She caught herself doing it in front of Ilias."
          }
        ]
      }

      assert {:ok, [entry]} = ArcSchema.parse(data)
      assert entry.reason == "She caught herself doing it in front of Ilias."

      row = ArcEntry.put(Repo, entry, "wren")
      assert row.reason == "She caught herself doing it in front of Ilias."
      assert [%Arc{reason: r}] = ArcEntry.canon_for_character(Repo, "wren") ++ [entry]
      assert is_binary(r)
    end

    test "a model that skips it still produces a usable proposal" do
      data = %{"entries" => [%{"kind" => "discovery", "statement" => "Something happened."}]}

      assert {:ok, [entry]} = ArcSchema.parse(data)
      assert entry.reason == nil
      assert entry.statement == "Something happened."
    end
  end

  describe "a line gave" do
    test "a canon release opens the boundary permanently" do
      sheet = %CharacterSheet{
        name: "Wren",
        boundaries: [
          %Boundary{
            topic: "Cover for her father",
            direction: :compulsion,
            stance: :conditional,
            condition: "she sees what it cost"
          },
          %Boundary{topic: "Leave Saltmarch", stance: :closed}
        ]
      }

      release = %Arc{
        kind: :release,
        released_topic: "Cover for her father",
        statement: "Covering for her father — it broke.",
        status: :canon,
        beat: 4
      }

      out = EffectiveSheet.apply(sheet, [release])

      assert [%Boundary{topic: "Cover for her father", stance: :open}, %Boundary{stance: :closed}] =
               out.boundaries
    end

    test "it only becomes permanent once it's canon — a proposal changes nothing" do
      sheet = %CharacterSheet{boundaries: [%Boundary{topic: "Name her father", stance: :closed}]}
      proposal = %Arc{kind: :release, released_topic: "Name her father", statement: "x"}

      assert EffectiveSheet.apply(sheet, [proposal]) == sheet
    end

    test "a topic that no longer matches is a no-op, not a crash" do
      sheet = %CharacterSheet{boundaries: [%Boundary{topic: "Name her father", stance: :closed}]}

      release = %Arc{
        kind: :release,
        released_topic: "Something else entirely",
        statement: "x",
        status: :canon
      }

      assert EffectiveSheet.apply(sheet, [release]) == sheet
    end

    test "the extractor can propose one" do
      data = %{
        "entries" => [
          %{
            "kind" => "release",
            "released_topic" => "Cover for her father",
            "statement" => "It broke.",
            "reason" => "Ilias counted the crates in front of her."
          }
        ]
      }

      assert {:ok, [%Arc{kind: :release, released_topic: "Cover for her father"}]} =
               ArcSchema.parse(data)
    end
  end

  describe "world arc says who knows" do
    test "everyone is common knowledge — it folds in public" do
      data = %{
        "entries" => [
          %{
            "kind" => "discovery",
            "scope" => "global",
            "known_by" => "everyone",
            "statement" => "The tide bell has been rung twice in a night.",
            "reason" => "Wren rang it."
          }
        ]
      }

      assert {:ok, [entry]} = WorldArcSchema.parse(data)
      refute entry.concealed
      assert entry.reason == "Wren rang it."

      folded = EffectiveWorldBible.apply(%WorldBible{}, [%{entry | status: :canon}], :all)
      assert WorldBible.public(folded.starting_canon) == [entry.statement]
    end

    test "whoever was there folds in concealed, resolving against that scene's cast" do
      data = %{
        "entries" => [
          %{
            "kind" => "discovery",
            "scope" => "global",
            "known_by" => "scene",
            "statement" => "The count is written down somewhere Aldous can't reach."
          }
        ]
      }

      assert {:ok, [entry]} = WorldArcSchema.parse(data)
      assert entry.concealed
      assert %Audience{scene: true} = entry.audience

      canon = %{entry | status: :canon, source_scene_id: "S1"}

      # Nobody, with no way to look the scene up — default-deny.
      blind = EffectiveWorldBible.apply(%WorldBible{}, [canon], :all)
      assert WorldBible.known_to(blind.starting_canon, "wren") == []

      # **Expanded at fold time**, unlike a group. A scene's cast is finished history
      # and can't change, so resolving it once is safe; a group's membership moves,
      # which is exactly why naming it rather than expanding it is the point.
      folded =
        EffectiveWorldBible.apply(%WorldBible{}, [canon], :all,
          scene_members: fn "S1" -> ["wren", "ilias"] end
        )

      assert WorldBible.known_to(folded.starting_canon, "wren") == [entry.statement]
      assert WorldBible.known_to(folded.starting_canon, "corrigan") == []
    end

    test "scope and audience stay different axes" do
      local = %WorldArcEntry{
        kind: :discovery,
        statement: "The undercroft flooded.",
        status: :canon,
        scope: :local,
        location_id: "the undercroft"
      }

      # Local reach, public knowledge: everyone there knows, nobody elsewhere is told.
      here = EffectiveWorldBible.apply(%WorldBible{}, [local], "the undercroft")
      away = EffectiveWorldBible.apply(%WorldBible{}, [local], "the quay")

      assert WorldBible.public(here.starting_canon) == ["The undercroft flooded."]
      assert WorldBible.public(away.starting_canon) == []
    end
  end

  describe "accepting" do
    test "accept_all promotes every proposal for a subject in one write" do
      for i <- 1..3 do
        ArcEntry.put(Repo, %Arc{kind: :discovery, statement: "fact #{i}"}, "wren")
      end

      assert ArcEntry.accept_all(Repo, "wren") == 3
      assert ArcEntry.list_proposed(Repo, "wren") == []
      assert length(ArcEntry.canon_for_character(Repo, "wren")) == 3
    end

    test "something accepted in March can be taken back in June" do
      row =
        ArcEntry.put(Repo, %Arc{kind: :discovery, statement: "wrong, as it turns out"}, "wren")

      ArcEntry.accept(Repo, row.id)
      assert length(ArcEntry.canon_for_character(Repo, "wren")) == 1

      ArcEntry.retract(Repo, row.id)
      assert ArcEntry.canon_for_character(Repo, "wren") == []
      # And it doesn't come back as a proposal — retracted is retracted.
      assert ArcEntry.list_proposed(Repo, "wren") == []
    end
  end

  describe "a group changing" do
    setup do
      owner = owner()
      group = Groups.create(owner, %Group{name: "The Tidewatch"})
      sable = character(owner, "Sable Quist")
      bellman = character(owner, "The bellman")
      corrigan = character(owner, "Mother Corrigan")

      for c <- [sable, bellman, corrigan], do: {:ok, _} = Groups.add_member(group.id, c.id)

      %{group: group, sable: sable, bellman: bellman, corrigan: corrigan}
    end

    test "fans out into one proposal for the group and one per member", %{group: group} do
      entry = %Arc{
        kind: :revision,
        statement: "They have started meeting in daylight.",
        reason: "Three of them were seen on the quay before noon."
      }

      out = GroupArc.fan_out(group.id, entry)

      assert length(out.members) == 3
      assert GroupArc.counts(group.id) == %{group: 1, members: 3}
    end

    test "a member who joined by hand gets one too — membership is what matters",
         %{group: group, corrigan: corrigan} do
      GroupArc.fan_out(group.id, %Arc{kind: :discovery, statement: "They meet in daylight."})

      assert ArcEntry.list_proposed(Repo, corrigan.id) != []
    end

    test "nothing propagates silently — each is its own yes or no",
         %{group: group, sable: sable, bellman: bellman} do
      GroupArc.fan_out(group.id, %Arc{kind: :discovery, statement: "They meet in daylight."})

      # Accept the group's and Sable's; refuse the bellman's. That's the dissent the
      # design says is the most useful button on the screen.
      [group_row] = ArcEntry.list_proposed(Repo, group.id, "group")
      [sable_row] = ArcEntry.list_proposed(Repo, sable.id)
      [bellman_row] = ArcEntry.list_proposed(Repo, bellman.id)

      ArcEntry.accept(Repo, group_row.id)
      ArcEntry.accept(Repo, sable_row.id)
      ArcEntry.reject(Repo, bellman_row.id)

      assert length(ArcEntry.canon_for_character(Repo, sable.id)) == 1
      assert ArcEntry.canon_for_character(Repo, bellman.id) == []
      # The group changed and he didn't.
      assert ArcEntry.list_canon(Repo, group.id, "group") != []
    end

    test "accept-all clears the whole card in one tap", %{group: group} do
      GroupArc.fan_out(group.id, %Arc{kind: :discovery, statement: "They meet in daylight."})

      assert GroupArc.accept_all(group.id) == 4
      assert GroupArc.counts(group.id) == %{group: 0, members: 0}
    end

    test "an extractor with an opinion writes each member's own statement",
         %{group: group, sable: sable} do
      per_member = fn id ->
        if to_string(id) == to_string(sable.id) do
          %Arc{kind: :discovery, statement: "She has stopped pretending the bell is only a bell."}
        end
      end

      GroupArc.fan_out(group.id, %Arc{kind: :discovery, statement: "They meet in daylight."},
        for_member: per_member
      )

      assert [%{statement: "She has stopped pretending the bell is only a bell."}] =
               ArcEntry.list_proposed(Repo, sable.id)
    end

    test "a group's own arc doesn't block a scene it isn't in", %{group: group} do
      GroupArc.fan_out(group.id, %Arc{kind: :discovery, statement: "They meet in daylight."})

      # Filed under "group", so a character-scoped gate never sees it.
      assert ArcEntry.list_proposed(Repo, group.id, "character") == []
      assert ArcEntry.list_proposed(Repo, group.id, "group") != []
    end
  end
end
