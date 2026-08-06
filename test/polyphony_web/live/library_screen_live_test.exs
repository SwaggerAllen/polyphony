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

  defp open_menu(view, entry) do
    view
    |> element(~s(button[phx-click="row_menu"][phx-value-id="#{entry.id}"]))
    |> render_click()
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

    test "every campaign can be opened, whatever state it is in", %{conn: conn, user: user} do
      playing = campaign(user, %{name: "The Salt Line", scenes: ["s1"]})
      fresh = campaign(user, %{name: ""})

      {:ok, _view, html} = live(conn, ~p"/library")

      # The only link on a row used to be "Carry on", which is `:playing` only — so a
      # campaign you had just made had nothing to click, and an untitled one looked
      # like a dead entry rather than an unopened one.
      assert html =~ ~s(href="/campaigns/#{playing.id}")
      assert html =~ ~s(href="/campaigns/#{fresh.id}")
    end

    test "a row can be filed or thrown away, which nothing could do", %{conn: conn, user: user} do
      entry = campaign(user, %{name: "The Salt Line"})
      {:ok, view, _html} = live(conn, ~p"/library")

      # The row's menu is an overlay, so its contents don't exist until it is opened —
      # which is the point: opening it used to push every row below it down the page.
      open_menu(view, entry)

      # `Library.archive/2` had no caller anywhere, so the Archive shelf this screen is
      # the front door for could only ever be empty.
      view
      |> element(~s(button[phx-click="archive"][phx-value-id="#{entry.id}"]))
      |> render_click()

      assert [%{id: id}] = Library.archived(Owner.of(user))
      assert id == entry.id
      refute Enum.any?(Library.list_for_owner(Owner.of(user)), &(&1.id == entry.id))
    end

    test "trash is soft, and the row says so before you use it", %{conn: conn, user: user} do
      entry = campaign(user, %{name: "The Salt Line"})
      {:ok, view, html} = live(conn, ~p"/library")

      # Nothing about the menu is on the page until it is asked for.
      refute html =~ "Recoverable until it expires."

      # No confirmation here on purpose: the irreversible button lives on the trash
      # shelf, where the clock is visible.
      assert open_menu(view, entry) =~ "Recoverable until it expires."

      view |> element(~s(button[phx-click="trash"][phx-value-id="#{entry.id}"])) |> render_click()

      assert [%{id: id}] = Library.trash(Owner.of(user))
      assert id == entry.id
    end

    test "the row's menu is an overlay, so opening it displaces nothing", %{
      conn: conn,
      user: user
    } do
      entry = campaign(user, %{name: "The Salt Line"})
      {:ok, view, _html} = live(conn, ~p"/library")

      html = open_menu(view, entry)

      # In the flow, this panel pushed every row below it down the page — so the
      # campaign you were reading moved out from under you at the moment you touched
      # its menu. `.scrim` + `.overlay` are `position:fixed` and cost the page no
      # layout, and the scrim and Escape are two of the three ways back out.
      assert html =~ ~s(class="scrim")
      assert html =~ ~s(phx-click="close_row_menu")
      assert html =~ ~s(phx-key="Escape")

      # And it closes, leaving the screen as it was.
      assert render_click(view, "close_row_menu", %{}) =~ "The Salt Line"
      refute render(view) =~ ~s(class="scrim")
    end

    test "only the row you asked for opens", %{conn: conn, user: user} do
      salt = campaign(user, %{name: "The Salt Line"})
      _low = campaign(user, %{name: "Low Water"})

      {:ok, view, _html} = live(conn, ~p"/library")
      html = open_menu(view, salt)

      # One menu at a time, held by id rather than by a `<details>` per row — two open
      # overlays would stack on top of each other.
      assert [_] = Regex.scan(~r|class="scrim"|, html)
      assert html =~ ~s(aria-label="Change The Salt Line")
      refute html =~ ~s(aria-modal="true" aria-label="Change Low Water")
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

      # The tier pill at the top of the tab.
      opened = view |> element("button.pill[phx-value-tier=incidental]") |> render_click()
      assert opened =~ "A harbour constable"
      refute opened =~ "Wren Ashgrove"
    end

    test "and the collapsed row itself opens them", %{conn: conn, user: user} do
      main = character(user, "Wren Ashgrove")
      extra = character(user, "A harbour constable")
      {:ok, _} = Characters.set_tier(extra.id, :incidental)
      campaign(user, %{name: "The Salt Line", character_ids: [main.id, extra.id]})

      {:ok, view, html} = live(conn, ~p"/library?tab=people")

      # It was an `<a patch>` to the URL it was already on, carrying a `phx-click` to do
      # the work — and LiveView's nav handler calls `stopImmediatePropagation()` on a
      # `data-phx-link` click, so the ordinary click binding never saw it. Tapping the
      # row did nothing. The old test passed because `button[phx-value-tier=…]` matched
      # the *pill*, so the row it was named after was never clicked.
      refute html =~ ~r/<a[^>]*phx-value-tier="incidental"/

      opened = view |> element("button.row[phx-value-tier=incidental]") |> render_click()
      assert opened =~ "A harbour constable"
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

      # Attaching copies (§2.5b) — so without this the tab lists the same world twice,
      # one of which belongs to a campaign. The library keeps templates.
      #
      # Counted by row rather than by name: the row's ⋯ is labelled with the name too,
      # so counting the text would go up every time the row gains a control.
      assert Enum.count(Regex.scan(~r|href="/authoring/bible/|, html)) == 1
      refute html =~ ~s(href="/authoring/bible/#{copy.id}")
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

  describe "worlds and people can be reached, not only read" do
    test "a world row has a menu that edits and files it", %{conn: conn, user: user} do
      entry = world(user, "Saltmarch")
      {:ok, view, html} = live(conn, ~p"/library?tab=worlds")

      # Nothing but a link before: the tab could show you a world and offer you no way
      # to file one, throw one away, or do anything but open it.
      refute html =~ ~s(aria-modal="true")

      html = open_menu(view, entry)
      assert html =~ ~s(aria-modal="true" aria-label="Change Saltmarch")

      # "Edit", not "Open" — a world is a thing you write, and the verb is the
      # difference between a menu that reads as navigation and one that reads as filing.
      assert html =~ ~s(href="/authoring/bible/#{entry.id}")
      assert html =~ "Edit"

      view
      |> element(~s(button[phx-click="archive"][phx-value-id="#{entry.id}"]))
      |> render_click()

      assert [%{id: id}] = Library.archived(Owner.of(user))
      assert id == entry.id
    end

    test "and says what goes with it, which for a world is nothing",
         %{conn: conn, user: user} do
      entry = world(user, "Saltmarch")
      {:ok, view, _html} = live(conn, ~p"/library?tab=worlds")

      # The library lists templates only, and attaching copies (§2.5b) — so a campaign
      # started from this keeps its own. Worth saying before the press rather than
      # leaving somebody to guess whether they are about to break a running story.
      assert open_menu(view, entry) =~ "Campaigns started from it keep their own copy"
    end

    test "a person row has one too", %{conn: conn, user: user} do
      entry = character(user, "Wren")
      {:ok, view, _html} = live(conn, ~p"/library?tab=people")

      html = open_menu(view, entry)
      assert html =~ ~s(aria-modal="true" aria-label="Change Wren")
      assert html =~ ~s(href="/authoring/character/#{entry.id}")

      view |> element(~s(button[phx-click="trash"][phx-value-id="#{entry.id}"])) |> render_click()
      assert [%{id: id}] = Library.trash(Owner.of(user))
      assert id == entry.id
    end

    test "trashing somebody takes them off the cast, and putting them back restores it",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{name: "The Salt Line", character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/library?tab=people")
      open_menu(view, wren)
      view |> element(~s(button[phx-click="trash"][phx-value-id="#{wren.id}"])) |> render_click()

      # The roster still names them — the reference is harmless while they're gone,
      # because every read of a cast goes through `list_for_owner`, which excludes the
      # deleted. That is what makes restore complete rather than half a recovery.
      assert Library.payload(Library.get(camp.id))[:character_ids] == [wren.id]
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
      refute html =~ "Wren"

      {:ok, _} = Library.restore(wren.id)
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
      assert html =~ "Wren"
    end

    test "the menu says that, rather than leaving it to be discovered",
         %{conn: conn, user: user} do
      entry = character(user, "Wren")
      {:ok, view, _html} = live(conn, ~p"/library?tab=people")

      assert open_menu(view, entry) =~
               "They leave any cast they&#39;re in until you put them back."
    end

    test "one menu at a time across all three tabs", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      world(user, "Saltmarch")

      {:ok, view, _html} = live(conn, ~p"/library?tab=people")
      html = open_menu(view, wren)

      # `menu_for` is an id and an id is unique across the library, so the kind is
      # resolved from the row rather than carried through the click.
      assert [_] = Regex.scan(~r|class="scrim"|, html)
      assert html =~ ~s(aria-label="Change Wren")
    end
  end
end
