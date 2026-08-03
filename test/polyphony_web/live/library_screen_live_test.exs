defmodule PolyphonyWeb.LibraryScreenLiveTest do
  @moduledoc """
  The library as `ux/polyphony-library.html` draws it — the decisions, not the markup.

  Four of them, and each is a thing the old screen got wrong by being a create hub:

    * **One create button.** Worlds and characters are made inside a campaign, so the
      three-way "what do I make first" question doesn't get asked.
    * **People group by campaign for free** (§2.7), and walk-ons collapse — the tier
      you scan past shouldn't bury the two people you came for.
    * **A world says how many campaigns *started from* it** (§2.5b) — past tense,
      because attaching copies. Nothing here breaks by editing.
    * **Archive and trash are different shelves**, and the trash countdown is a
      number rather than a claim (§2.13).
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Campaigns, Characters, Library, Owner, Reading}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  setup :register_and_log_in_user

  defp campaign(user, attrs) do
    payload =
      Map.merge(%{kind: :campaign, name: "The Salt Line", character_ids: [], scenes: []}, attrs)

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  defp character(user, name, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name, status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp world(user, name, attrs \\ %{}) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "world_bible",
      payload: struct(%WorldBible{name: name}, attrs)
    })
  end

  describe "one create button" do
    test "new campaign is the only create action, and goes straight to it", %{
      conn: conn,
      user: user
    } do
      {:ok, view, html} = live(conn, ~p"/library")

      # No character / world buttons: those are made inside a campaign now.
      refute html =~ "phx-value-kind=\"character\""
      refute html =~ "phx-value-kind=\"world_bible\""

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("button.btn-sm[phx-click=new_campaign]") |> render_click()

      assert [entry] = Library.list_for_owner(Owner.of(user))
      assert entry.kind == "campaign"
      assert to == "/campaigns/#{entry.id}"
    end

    test "first run says start a campaign, not what the three types are", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/library")

      assert html =~ "Nothing here yet."
      assert html =~ "A campaign is a world, some people, and the scenes"
      refute html =~ "World bible"
    end
  end

  describe "campaign rows" do
    test "a row says where the campaign is in its life", %{conn: conn, user: user} do
      campaign(user, %{name: "The Salt Line", scenes: ["s1"]})
      campaign(user, %{name: ""})

      {:ok, _view, html} = live(conn, ~p"/library")

      assert html =~ "The Salt Line"
      assert html =~ "Playing"
      # A campaign nobody has opened says so out loud, rather than looking broken.
      assert html =~ "Not started"
      assert html =~ "Untitled campaign"
    end

    test "a finished campaign stays on the shelf — it's a statement, not filing", %{
      conn: conn,
      user: user
    } do
      entry = campaign(user, %{name: "Low Water", scenes: ["s1"]})
      {:ok, _} = Campaigns.finish(entry.id)

      {:ok, _view, html} = live(conn, ~p"/library")

      assert html =~ "Low Water"
      assert html =~ "Finished"
    end

    test "the review count is the same number the scene gate stops you with", %{
      conn: conn,
      user: user
    } do
      wren = character(user, "Wren")
      entry = campaign(user, %{character_ids: [wren.id], scenes: ["s1"]})

      Polyphony.ReadModels.ArcEntry.put(
        Polyphony.Repo,
        %Polyphony.Authoring.ArcEntry{kind: :discovery, statement: "a"},
        wren.id
      )

      {:ok, _view, html} = live(conn, ~p"/library")

      assert html =~ "1 to review"
      assert Campaigns.pending_review(entry) == 1
    end

    test "the archive and trash counts are the front door they never had", %{
      conn: conn,
      user: user
    } do
      filed = campaign(user, %{name: "Filed"})
      binned = campaign(user, %{name: "Binned"})
      {:ok, _} = Library.archive(filed.id)
      {:ok, _} = Library.soft_delete(binned.id)

      {:ok, _view, html} = live(conn, ~p"/library")

      assert html =~ "1 archived"
      assert html =~ "1 in trash"
    end
  end

  describe "people" do
    test "group by campaign, because a character belongs to exactly one", %{
      conn: conn,
      user: user
    } do
      wren = character(user, "Wren Ashgrove")
      rusk = character(user, "Bellwether Rusk")
      character(user, "Nobody Yet")

      campaign(user, %{name: "The Salt Line", character_ids: [wren.id]})
      campaign(user, %{name: "Low Water", character_ids: [rusk.id]})

      {:ok, _view, html} = live(conn, ~p"/library?tab=people")

      assert html =~ "The Salt Line"
      assert html =~ "Wren Ashgrove"
      assert html =~ "Bellwether Rusk"
      # Someone in no campaign yet is still findable, in a trailing group.
      assert html =~ "Not in a campaign"
      assert html =~ "Nobody Yet"
    end

    test "walk-ons collapse behind a count, and filtering to them opens them", %{
      conn: conn,
      user: user
    } do
      main = character(user, "Wren Ashgrove")
      extra = character(user, "A harbour constable")
      {:ok, _} = Characters.set_tier(extra.id, :incidental)
      campaign(user, %{name: "The Salt Line", character_ids: [main.id, extra.id]})

      {:ok, view, html} = live(conn, ~p"/library?tab=people")

      assert html =~ "Wren Ashgrove"
      assert html =~ "1 walk-on"
      refute html =~ "A harbour constable"

      opened = view |> element("button[phx-value-tier=incidental]") |> render_click()
      assert opened =~ "A harbour constable"
      refute opened =~ "Wren Ashgrove"
    end

    test "search narrows by name and by what they are", %{conn: conn, user: user} do
      character(user, "Wren Ashgrove", %{premise: "The harbourmaster's daughter"})
      character(user, "Ilias Vane", %{premise: "A customs inspector"})

      {:ok, view, _html} = live(conn, ~p"/library?tab=people")

      by_name = view |> form("form[phx-change=search]", %{q: "wren"}) |> render_change()
      assert by_name =~ "Wren Ashgrove"
      refute by_name =~ "Ilias Vane"

      by_role = view |> form("form[phx-change=search]", %{q: "customs"}) |> render_change()
      assert by_role =~ "Ilias Vane"
      refute by_role =~ "Wren Ashgrove"
    end

    test "nothing found says to clear the tier filters, not 'no results'", %{
      conn: conn,
      user: user
    } do
      character(user, "Wren Ashgrove")
      {:ok, view, _html} = live(conn, ~p"/library?tab=people")

      html = view |> form("form[phx-change=search]", %{q: "alchemist"}) |> render_change()

      assert html =~ "Nobody by that name."
      assert html =~ "walk-ons are hidden more often than people expect"
    end
  end

  describe "worlds" do
    test "a world counts the campaigns that started from it, in the past tense", %{
      conn: conn,
      user: user
    } do
      saltmarch = world(user, "Saltmarch", %{cover: "A port town that runs on tides."})
      first = Library.copy(saltmarch, Owner.of(user))
      second = Library.copy(saltmarch, Owner.of(user))
      campaign(user, %{name: "The Salt Line", bible_id: first.id})
      campaign(user, %{name: "Low Water", bible_id: second.id})
      world(user, "Untouched")

      {:ok, _view, html} = live(conn, ~p"/library?tab=worlds")

      assert html =~ "Saltmarch"
      assert html =~ "2 campaigns started from this"
      # Never attached reads as never used, not as zero dependants.
      assert html =~ "Never used"
    end

    test "a campaign's own copy is not a second library world", %{conn: conn, user: user} do
      saltmarch = world(user, "Saltmarch")
      copy = Library.copy(saltmarch, Owner.of(user))
      campaign(user, %{name: "The Salt Line", bible_id: copy.id})

      {:ok, _view, html} = live(conn, ~p"/library?tab=worlds")

      # Attaching copies (§2.5b) — so without this the tab lists the same name twice,
      # one of which belongs to a campaign. The library keeps templates.
      assert Enum.count(Regex.scan(~r/Saltmarch/, html)) == 1
      assert html =~ "1 campaign started from this"
    end

    test "the library wears the visibility badge but doesn't set it", %{conn: conn, user: user} do
      entry = world(user, "The Ninth Gate")
      Library.set_visibility(entry.id, "public")

      {:ok, _view, html} = live(conn, ~p"/library?tab=worlds")

      assert html =~ "Public"
      # No control — visibility lives next to the thing itself.
      refute html =~ "phx-change=\"visibility\""
    end
  end

  describe "archive and trash" do
    test "they are different shelves, and only one has a clock", %{conn: conn, user: user} do
      filed = world(user, "Filed World")
      binned = world(user, "Binned World")
      {:ok, _} = Library.archive(filed.id)
      {:ok, _} = Library.soft_delete(binned.id)

      {:ok, _view, html} = live(conn, ~p"/library?tab=shelves")

      assert html =~ "Filed World"
      assert html =~ "Binned World"
      # The countdown is the whole point (§2.13).
      assert html =~ "Gone for good in #{Library.retention_days()} days"
      assert html =~ "Archive is filing, not deleting"
    end

    test "restoring an archived entry puts it back with one button", %{conn: conn, user: user} do
      entry = world(user, "Filed World")
      {:ok, _} = Library.archive(entry.id)

      {:ok, view, _html} = live(conn, ~p"/library?tab=shelves")
      view |> element("button[phx-click=unarchive][phx-value-id='#{entry.id}']") |> render_click()

      assert Library.get(entry.id).archived_at == nil
      assert Enum.any?(Library.list_for_owner(Owner.of(user)), &(&1.id == entry.id))
    end

    test "putting something back takes it off the clock", %{conn: conn, user: user} do
      entry = world(user, "Binned World")
      {:ok, _} = Library.soft_delete(entry.id)

      {:ok, view, _html} = live(conn, ~p"/library?tab=shelves")
      view |> element("button[phx-click=restore][phx-value-id='#{entry.id}']") |> render_click()

      assert Library.trash(Owner.of(user)) == []
    end

    test "delete now really goes, and is the one button that confirms", %{conn: conn, user: user} do
      entry = world(user, "Binned World")
      {:ok, _} = Library.soft_delete(entry.id)

      {:ok, view, html} = live(conn, ~p"/library?tab=shelves")
      assert html =~ "There&#39;s no getting it back."

      view |> element("button[phx-click=purge][phx-value-id='#{entry.id}']") |> render_click()

      assert Library.get(entry.id) == nil
    end

    test "an empty trash still states the window, because that's the promise", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/library?tab=shelves")

      assert html =~ "Deleted things wait #{Library.retention_days()} days"
    end
  end

  describe "reading" do
    test "a story you're partway through keeps its place and its perspective", %{
      conn: conn,
      user: user
    } do
      author = user_fixture()

      story =
        Library.put(%{
          owner: Owner.of(author),
          kind: "campaign",
          visibility: "public",
          payload: %{kind: :campaign, name: "The Ninth Gate", scenes: ["s1", "s2", "s3"]}
        })

      Reading.mark(Owner.of(user), story.id, %{scene_id: "s2", beat: 4, perspective: "halden"})

      {:ok, _view, html} = live(conn, ~p"/library?tab=reading")

      assert html =~ "The Ninth Gate"
      assert html =~ "Scene 2 of 3."
      # Perspective is part of where you were, so the row wears it.
      assert html =~ "As halden"
      assert html =~ "Carry on reading"
    end

    test "unpublished out from under you keeps the row and drops the promise", %{
      conn: conn,
      user: user
    } do
      author = user_fixture()

      story =
        Library.put(%{
          owner: Owner.of(author),
          kind: "campaign",
          visibility: "public",
          payload: %{kind: :campaign, name: "The Long Quiet", scenes: ["s1"]}
        })

      Reading.mark(Owner.of(user), story.id, %{scene_id: "s1", beat: 2})
      Library.set_visibility(story.id, "private")

      {:ok, _view, html} = live(conn, ~p"/library?tab=reading")

      assert html =~ "Gone"
      assert html =~ "Your place is kept in case it comes back."
      refute html =~ "Carry on reading"
      # And it really is kept.
      assert {"s1", 2, _} = Reading.resume(Owner.of(user), story.id)
    end

    test "nothing yet points at browse rather than at a create button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/library?tab=reading")

      assert html =~ "You&#39;re not reading anything."
      assert html =~ "Have a look"
    end
  end

  describe "scoping" do
    test "another owner's library is not shown", %{conn: conn} do
      other = user_fixture()

      Library.put(%{
        owner: Owner.of(other),
        kind: "character",
        payload: %CharacterSheet{name: "Secret", status: :full}
      })

      {:ok, _view, html} = live(conn, ~p"/library?tab=people")
      refute html =~ "Secret"
    end
  end
end
