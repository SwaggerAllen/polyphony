defmodule PolyphonyWeb.PermissionsLiveTest do
  @moduledoc """
  You edit what you own. Everything else you copy.

  The hole this closes: every authoring screen loaded a library entry by the id in its
  URL and checked only that it existed and hadn't been moderated. `Owner` had been
  threaded through every *read* since §P2 and every list was scoped correctly — nothing
  scoped the entry a URL named. Library ids are small integers and scene ids are
  `sc-<counter>`, so any signed-in account could open a stranger's campaign, world,
  character, group, arc review or live scene and write to it.

  Two things are pinned here, and the second matters as much as the first:

    * a stranger is refused on every one of those surfaces, and on the id-taking
      handlers behind them — casting someone into a scene, attaching a world, joining a
      group — because a gate on the mount is worth nothing if the form beneath it takes
      an arbitrary id; and
    * the refusal **doesn't confirm the id exists**. A private entry is "not found",
      the same words a missing one gets, because a distinct "not allowed" is a fact
      about somebody else's account. Only something already published says whose it is,
      and then it says the useful thing: take a copy.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Groups, Library, Owner, Permissions}
  alias Polyphony.Authoring.{CharacterSheet, Group, WorldBible}

  setup :register_and_log_in_user

  setup %{user: user} do
    # Somebody else, with one of everything.
    stranger = user_fixture()

    world =
      Library.put(%{
        owner: Owner.of(stranger),
        kind: "world_bible",
        payload: %WorldBible{name: "Saltmarch", setting: "Not yours."}
      })

    character =
      Library.put(%{
        owner: Owner.of(stranger),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full}
      })

    group = Groups.create(Owner.of(stranger), %Group{name: "The Tidewatch"})

    campaign =
      Library.put(%{
        owner: Owner.of(stranger),
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "Theirs",
          character_ids: [character.id],
          bible_id: world.id,
          scenes: []
        }
      })

    %{
      user: user,
      stranger: stranger,
      world: world,
      character: character,
      group: group,
      campaign: campaign
    }
  end

  defp mine(user, kind, payload),
    do: Library.put(%{owner: Owner.of(user), kind: kind, payload: payload})

  describe "somebody else's things" do
    test "the world editor refuses, and doesn't say the id is real",
         %{conn: conn, world: world} do
      assert {:error, {:redirect, %{to: "/library", flash: flash}}} =
               live(conn, ~p"/authoring/bible/#{world.id}")

      # The same words a missing id gets. "You're not allowed" would confirm that the
      # number belongs to something.
      assert flash["error"] == "World bible not found."
    end

    test "so does the character editor", %{conn: conn, character: character} do
      assert {:error, {:redirect, %{to: "/library", flash: flash}}} =
               live(conn, ~p"/authoring/character/#{character.id}")

      assert flash["error"] == "Character not found."
    end

    test "so does the group editor", %{conn: conn, group: group} do
      assert {:error, {:redirect, %{to: "/library"}}} =
               live(conn, ~p"/authoring/group/#{group.id}")
    end

    test "so does the campaign screen", %{conn: conn, campaign: campaign} do
      assert {:error, {:redirect, %{to: "/library"}}} = live(conn, ~p"/campaigns/#{campaign.id}")
    end

    test "so does arc review, which accepts changes onto their characters",
         %{conn: conn, campaign: campaign} do
      assert {:error, {:redirect, %{to: "/library"}}} = live(conn, ~p"/arc/#{campaign.id}")
    end
  end

  describe "something they published" do
    test "points at the copy, because that is the actual answer", %{conn: conn, world: world} do
      {:ok, _} = Library.set_visibility(world.id, :public)

      assert {:error, {:redirect, %{to: "/browse", flash: flash}}} =
               live(conn, ~p"/authoring/bible/#{world.id}")

      # Not a consolation — it's the design (§2.5b). A world is a template and taking
      # one copies it; editing somebody's in place was never the affordance.
      assert flash["info"] =~ "someone else's"
      assert flash["info"] =~ "Take a copy"
    end
  end

  describe "your own things" do
    test "open normally", %{conn: conn, user: user} do
      world = mine(user, "world_bible", %WorldBible{name: "Mine"})
      character = mine(user, "character", %CharacterSheet{name: "Mine", status: :full})
      group = Groups.create(Owner.of(user), %Group{name: "Mine"})

      assert {:ok, _view, _html} = live(conn, ~p"/authoring/bible/#{world.id}")
      assert {:ok, _view, _html} = live(conn, ~p"/authoring/character/#{character.id}")
      assert {:ok, _view, _html} = live(conn, ~p"/authoring/group/#{group.id}")
    end
  end

  describe "a scene" do
    setup %{stranger: stranger} do
      camp =
        Library.put(%{
          owner: Owner.of(stranger),
          kind: "campaign",
          payload: %{kind: :campaign, name: "Theirs", character_ids: [], scenes: []}
        })

      scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))

      :ok =
        Polyphony.App.dispatch(%Polyphony.Commands.OpenScene{
          scene_id: scene,
          campaign_id: camp.id,
          opened_beat: 0
        })

      %{their_scene: scene, their_campaign: camp}
    end

    test "belonging to someone else can't be walked into", %{conn: conn, their_scene: scene} do
      # Scene ids are `sc-<counter>`. Playing dispatches commands, so this was not a
      # read leak — it was a write into a stranger's story.
      assert {:error, {:redirect, %{to: "/library", flash: flash}}} =
               live(conn, ~p"/play/#{scene}")

      assert flash["error"] == "Scene not found."
    end

    test "belonging to you opens", %{conn: conn, user: user} do
      camp =
        Library.put(%{
          owner: Owner.of(user),
          kind: "campaign",
          payload: %{kind: :campaign, name: "Mine", character_ids: [], scenes: []}
        })

      scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))

      :ok =
        Polyphony.App.dispatch(%Polyphony.Commands.OpenScene{
          scene_id: scene,
          campaign_id: camp.id,
          opened_beat: 0
        })

      assert {:ok, _view, _html} = live(conn, ~p"/play/#{scene}")
    end

    test "the campaign screen always stamps the campaign on one it opens",
         %{conn: conn, user: user} do
      # `can_play?/2` allows a scene with no campaign, because authorising on a missing
      # field is worse than the alternative and the domain layer is deliberately usable
      # without the web layer. That is only safe while nothing a user can reach produces
      # one — which is what this pins.
      char = mine(user, "character", %CharacterSheet{name: "Wren", status: :full})

      camp =
        mine(user, "campaign", %{
          kind: :campaign,
          name: "Mine",
          character_ids: [char.id],
          scenes: []
        })

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      render_click(view, "start_scene", %{})

      [scene | _] = Library.payload(Library.get(camp.id))[:scenes]

      opened =
        for %Polyphony.Events.SceneOpened{} = e <-
              Polyphony.App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data),
            do: e

      assert [%{campaign_id: cid}] = opened
      assert cid == camp.id
    end
  end

  describe "the handlers behind the screens" do
    test "a stranger's character can't be cast by id", %{
      conn: conn,
      user: user,
      character: theirs
    } do
      camp =
        mine(user, "campaign", %{kind: :campaign, name: "Mine", character_ids: [], scenes: []})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      # The picker only offers your own people, but the id comes back in a form — and
      # the cast is what feeds every character's context.
      html = render_submit(view, "add_character", %{"id" => to_string(theirs.id)})

      assert html =~ "isn&#39;t yours to cast"
      assert Library.payload(Library.get(camp.id))[:character_ids] == []
    end

    test "a stranger's world can't be attached by id", %{conn: conn, user: user, world: theirs} do
      camp =
        mine(user, "campaign", %{kind: :campaign, name: "Mine", character_ids: [], scenes: []})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      # Attaching *copies*, so this was a way to take a private bible — secrets and all
      # — straight out of somebody else's library.
      html = render_change(view, "select_world", %{"bible_id" => to_string(theirs.id)})

      assert html =~ "isn&#39;t yours to attach"
      assert Library.payload(Library.get(camp.id))[:bible_id] == nil
    end

    test "a character can't be joined to a stranger's group by id",
         %{conn: conn, user: user, group: theirs} do
      char = mine(user, "character", %CharacterSheet{name: "Mine", status: :full})
      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{char.id}")

      # Membership is what resolves an audience, so this was a way into somebody else's
      # secrets rather than merely a write.
      html = render_submit(view, "join_group", %{"group_id" => to_string(theirs.id)})

      assert html =~ "isn&#39;t yours"
      assert Groups.member_ids(theirs.id) == []
    end
  end

  describe "the library's destructive buttons" do
    test "a stranger's campaign can't be trashed by id", %{conn: conn, campaign: theirs} do
      {:ok, view, _html} = live(conn, ~p"/library")

      # The lists are scoped to the owner, so the buttons only ever *appear* on your own
      # things — but the id comes back in the event and `Library.soft_delete/1` doesn't
      # ask whose entry it is. Destroying somebody's campaign was a matter of knowing a
      # small integer.
      render_click(view, "trash", %{"id" => to_string(theirs.id)})

      assert Library.live?(Library.get(theirs.id))
    end

    test "nor archived, nor purged out of existence", %{conn: conn, world: theirs} do
      {:ok, view, _html} = live(conn, ~p"/library")

      render_click(view, "archive", %{"id" => to_string(theirs.id)})
      assert Library.live?(Library.get(theirs.id))

      render_click(view, "purge", %{"id" => to_string(theirs.id)})
      assert Library.get(theirs.id)
    end

    test "your own still archive and come back", %{conn: conn, user: user} do
      entry = mine(user, "world_bible", %WorldBible{name: "Mine"})
      {:ok, view, _html} = live(conn, ~p"/library")

      render_click(view, "archive", %{"id" => to_string(entry.id)})
      refute Library.live?(Library.get(entry.id, include_archived: true))

      # And restoring has to see it, which is why the check looks past the default
      # lists — otherwise putting your own work back would refuse itself.
      render_click(view, "unarchive", %{"id" => to_string(entry.id)})
      assert Library.live?(Library.get(entry.id))
    end
  end

  describe "the rule itself" do
    test "a frozen entry is nobody's to edit, its owner included", %{user: user} do
      entry = mine(user, "world_bible", %WorldBible{name: "Mine"})
      frozen = %{entry | frozen: true}

      # Republishing replaces a snapshot; it is never edited in place. Without this
      # clause "the owner may edit their own things" would quietly make them mutable.
      assert Permissions.can_edit?(entry, user)
      refute Permissions.can_edit?(frozen, user)
    end

    test "signed out is never edit access", %{user: user} do
      entry = mine(user, "world_bible", %WorldBible{name: "Mine"})
      refute Permissions.can_edit?(entry, nil)
      refute Permissions.can_edit?(nil, user)
    end

    test "shared editing plugs in at one function", %{user: user, stranger: stranger} do
      entry = mine(user, "world_bible", %WorldBible{name: "Mine"})

      # `editors_of/1` is the whole multiplayer seam: empty today, and every screen
      # already asks `can_edit?/2` rather than comparing owners itself.
      assert Permissions.editors_of(entry) == []
      refute Permissions.can_edit?(entry, stranger)
    end
  end
end
