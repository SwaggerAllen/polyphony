defmodule PolyphonyWeb.AdminScreenLiveTest do
  @moduledoc """
  Moderation as `ux/polyphony-admin.html` draws it.

  Four things the screen has to get right, and each has a test here:

    * **Child safety is its own lane** — never a filter on a general queue.
    * **Reading a report bypasses publication scope**, so the screen says so out loud
      and asks why. A reason field turns an unlogged habit into a decision.
    * **Content and people are different objects** — never one button.
    * **A take-down spreads**, and its forks go to a review lane rather than down with
      it, because a fork may have diverged past anything objectionable.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Accounts, Library, Moderation, Owner}

  setup do
    _ = Polyphony.Accounts.Roles.roles()
    :ok
  end

  defp admin_conn(conn) do
    admin = user_fixture(%{role: "admin"})
    {log_in_user(conn, admin), admin}
  end

  defp published(owner, visibility \\ "public") do
    Library.put(%{
      owner: Owner.of(owner),
      kind: "campaign",
      visibility: visibility,
      frozen: true,
      payload: %{kind: :campaign, name: "The Long Quiet"}
    })
  end

  defp report(reporter, owner, entry, reason \\ "harassment", detail \\ "please look") do
    {:ok, report} =
      Moderation.file_report(reporter, %{
        item_type: "library_entry",
        item_id: entry.id,
        owner_id: owner.id,
        reason: reason,
        detail: detail
      })

    report
  end

  describe "authorization" do
    test "a non-admin cannot reach the console", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end
  end

  describe "the queue" do
    test "child safety is its own lane, above everything else", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)
      owner = user_fixture()
      entry = published(owner)

      report(user_fixture(), owner, entry, "harassment")
      report(user_fixture(), owner, entry, "csam")

      {:ok, _view, html} = live(conn, ~p"/admin")

      assert html =~ "Child safety · 1"
      assert html =~ "Everything else · 1"
      # The urgent one comes first in the document, not just in a filter.
      assert :binary.match(html, "Child safety") < :binary.match(html, "Everything else")
      assert html =~ "Look at it"
    end

    test "an empty queue says so in the fiction's voice", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/admin")

      assert html =~ "Nothing waiting."
      assert html =~ "oldest first inside"
    end
  end

  describe "one report" do
    test "carries enough context to decide, both directions", %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      owner = user_fixture()
      entry = published(owner)

      {:ok, _} = Moderation.dismiss(admin, report(user_fixture(), owner, entry))
      r = report(user_fixture(), owner, entry, "harassment", "she's my actual neighbour")

      {:ok, _view, html} = live(conn, ~p"/admin?#{[report: r.id]}")

      assert html =~ "Report ##{r.id}"
      assert html =~ "Harassment of a real person"
      assert html =~ "she&#39;s my actual neighbour"
      # The fourth report on the same thing usually means somebody's campaigning.
      assert html =~ "One previous report on this, dismissed"
      assert html =~ "history"
    end

    test "content and people are separate, never one button", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)
      owner = user_fixture()
      r = report(user_fixture(), owner, published(owner))

      {:ok, _view, html} = live(conn, ~p"/admin?#{[report: r.id]}")

      assert html =~ "The content"
      assert html =~ "The person"
      assert html =~ "Leave it up"
      assert html =~ "Take it down"
      assert html =~ "7 days"
      assert html =~ "Until we say"
    end

    test "leaving it up closes the report and returns to the queue", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)
      owner = user_fixture()
      r = report(user_fixture(), owner, published(owner))

      {:ok, view, _html} = live(conn, ~p"/admin?#{[report: r.id]}")
      view |> element("button[phx-click=dismiss]") |> render_click()

      assert Moderation.get_report(r.id).status == "dismissed"
      assert Moderation.lanes().rest == []
    end
  end

  describe "reading what wasn't published" do
    test "is asked for with a reason, and written down with your name on it", %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      owner = user_fixture()
      published(owner)
      r = report(user_fixture(), owner, published(owner))

      {:ok, view, _html} = live(conn, ~p"/admin?#{[report: r.id]}")

      asked = view |> element("button[phx-click=ask_unlock]") |> render_click()
      assert asked =~ "See the whole thing?"
      assert asked =~ "private thoughts, whispers and character"
      assert asked =~ "gets written down"

      opened =
        view |> form("#unlock-form", %{why: "the passage needs context"}) |> render_submit()

      assert opened =~ "Reading as the author · logged"

      assert [entry | _] = Moderation.audit_trail(admin.id)
      assert entry.action == "content_access"
      assert entry.metadata["why"] == "the passage needs context"
    end
  end

  describe "a take-down spreads" do
    test "and its forks go to a review lane rather than down with it", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)
      owner = user_fixture()
      forker = user_fixture()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      r = report(user_fixture(), owner, original)

      {:ok, view, html} = live(conn, ~p"/admin?#{[report: r.id]}")
      # The weight of it is named at the moment of taking it.
      assert html =~ "they lose the thing, not just its listing"
      assert html =~ "1 fork(s) go to the review lane"

      view |> element("button[phx-click=take_down]") |> render_click()

      assert Library.get(original.id).visibility == "private"
      assert Library.hidden?(Library.get(fork.id))

      {:ok, _view, queue} = live(conn, ~p"/admin")
      assert queue =~ "Forks of things taken down · 1"
      assert queue =~ "It may contain none of what was reported."
    end

    test "a diverged fork can be left up, and comes back as its owner had it", %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      owner = user_fixture()
      forker = user_fixture()

      original = published(owner)
      fork = Library.copy(original, Owner.of(forker))
      {:ok, _} = Library.set_visibility(fork.id, "public")
      {:ok, _} = Moderation.take_down(admin, report(user_fixture(), owner, original), "nope")

      {:ok, view, _html} = live(conn, ~p"/admin")
      view |> element("button[phx-click=leave_fork][phx-value-id='#{fork.id}']") |> render_click()

      refute Library.hidden?(Library.get(fork.id))
      assert Library.get(fork.id).visibility == "public"
    end
  end

  describe "what the author sees after a take-down" do
    test "their campaign is gone from the library, and the editor says why", %{conn: conn} do
      {admin_conn, admin} = admin_conn(Phoenix.ConnTest.build_conn())
      _ = admin_conn
      author = user_fixture()
      author_conn = log_in_user(conn, author)

      campaign =
        Library.put(%{
          owner: Owner.of(author),
          kind: "campaign",
          payload: %{kind: :campaign, name: "The Long Quiet", character_ids: [], scenes: []}
        })

      snapshot =
        Library.publish_campaign(
          %{owner: Owner.of(author), campaign_id: campaign.id, characters: [], arc: []},
          visibility: "public"
        )

      {:ok, _view, before} = live(author_conn, ~p"/library")
      assert before =~ "The Long Quiet"

      {:ok, _} = Moderation.take_down(admin, report(user_fixture(), author, snapshot), "upheld")

      # The deleted experience: it isn't in their library.
      {:ok, _view, html} = live(author_conn, ~p"/library")
      refute html =~ "The Long Quiet"

      # And going straight to it says why, rather than "not found".
      assert {:error, {:redirect, %{to: "/library", flash: flash}}} =
               live(author_conn, ~p"/campaigns/#{campaign.id}")

      assert flash["error"] =~ "taken down after a report"
    end

    test "and it's off browse and off its share link", %{conn: conn} do
      {_c, admin} = admin_conn(Phoenix.ConnTest.build_conn())
      author = user_fixture()
      entry = published(author, "unlisted")
      token = Library.get(entry.id).share_token

      {:ok, _} = Moderation.take_down(admin, report(user_fixture(), author, entry), "upheld")

      assert Library.get_by_share_token(token) == nil
      {:ok, _view, html} = live(conn, ~p"/browse")
      refute html =~ "The Long Quiet"
    end
  end

  describe "suspension" do
    test "hides everything shared and shows how long is left", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)
      owner = user_fixture()
      shared = published(owner, "unlisted")
      r = report(user_fixture(), owner, published(owner))

      {:ok, view, _html} = live(conn, ~p"/admin?#{[report: r.id]}")
      view |> element("button[phx-click=suspend][phx-value-days='30']") |> render_click()

      assert Library.hidden?(Library.get(shared.id))

      {:ok, _view, html} = live(conn, ~p"/admin?#{[tab: "suspended"]}")
      assert html =~ owner.username
      assert html =~ "30 days left"
      assert html =~ "things hidden"
      assert html =~ "Lift it"
    end

    test "and lifting it is reachable, because a one-way suspension is a deletion", %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      owner = user_fixture()
      shared = published(owner, "public")
      {:ok, _} = Moderation.suspend_user(admin, report(user_fixture(), owner, shared), 30)

      {:ok, view, _html} = live(conn, ~p"/admin?#{[tab: "suspended"]}")
      view |> element("button[phx-click=lift][phx-value-id='#{owner.id}']") |> render_click()

      refute Accounts.suspension_active?(Accounts.get(owner.id))
      assert Library.get(shared.id).visibility == "public"
      refute Library.hidden?(Library.get(shared.id))
    end
  end

  describe "the rest of it" do
    test "the audit tints privilege use, which is what it's for", %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      owner = user_fixture()

      {:ok, _} =
        Moderation.access_report_content(admin, report(user_fixture(), owner, published(owner)),
          why: "needed context"
        )

      {:ok, _view, html} = live(conn, ~p"/admin?#{[tab: "decided"]}")

      assert html =~ "Read an unpublished perspective"
      assert html =~ "needed context"
      assert html =~ "var(--pencil) 6%"
    end

    test "invites can be minted and say who came in through which", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/admin?#{[tab: "invites"]}")
      html = view |> element("button[phx-click=mint_invite]") |> render_click()

      assert html =~ "Unused · made"
      assert length(Accounts.list_invites()) == 1
    end

    test "a reusable one is a second button, and says what it is", %{conn: conn} do
      {conn, _admin} = admin_conn(conn)

      {:ok, view, _html} = live(conn, ~p"/admin?#{[tab: "invites"]}")
      html = view |> element("button[phx-click=mint_reusable]") |> render_click()

      # Two buttons rather than a switch beside one: these are different objects once
      # minted, and the row has to say which it is before anybody sends it anywhere.
      assert html =~ "Reusable — stays valid"
      assert html =~ "never used"
      assert [%{reusable: true}] = Accounts.list_invites()
    end

    test "and it can be closed, because it never closes itself", %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      {:ok, invite} = Accounts.create_invite(admin, reusable: true)

      {:ok, view, html} = live(conn, ~p"/admin?#{[tab: "invites"]}")
      assert html =~ "Revoke"

      closed =
        view
        |> element("button[phx-click=revoke_invite][phx-value-id='#{invite.id}']")
        |> render_click()

      assert closed =~ "Closed ·"
      # Not a delete: the row stays, so an account that came in through it keeps its
      # provenance. And a closed invite has nothing left to revoke.
      assert length(Accounts.list_invites()) == 1
      refute closed =~ "Revoke"
      assert Accounts.open_invite(invite.token) == nil
    end

    test "the code can be copied, since it is meant to be typed into another device",
         %{conn: conn} do
      {conn, admin} = admin_conn(conn)
      {:ok, invite} = Accounts.create_invite(admin, reusable: true)

      {:ok, _view, html} = live(conn, ~p"/admin?#{[tab: "invites"]}")

      assert html =~ ~s(data-copy-target="invite-#{invite.id}")
      assert html =~ ~s(id="invite-#{invite.id}")
    end

    test "demotion exists, and the first account stays pinned", %{conn: conn} do
      boss = user_fixture(%{role: "superadmin"})
      conn = log_in_user(conn, boss)
      other = user_fixture(%{role: "admin"})

      {:ok, view, html} = live(conn, ~p"/admin?#{[tab: "admins"]}")
      assert html =~ "Can&#39;t be changed"

      view |> element("button[phx-click=demote][phx-value-id='#{other.id}']") |> render_click()

      assert Accounts.get(other.id).role == "user"
      # And the superadmin has no such button at all.
      refute render(view) =~ "phx-value-id=\"#{boss.id}\""
    end

    test "promotion is by name, and says so when there's nobody there", %{conn: conn} do
      boss = user_fixture(%{role: "superadmin"})
      conn = log_in_user(conn, boss)
      target = user_fixture()

      {:ok, view, _html} = live(conn, ~p"/admin?#{[tab: "admins"]}")

      view |> form("#promote-form", %{username: target.username}) |> render_submit()
      assert Accounts.get(target.id).role == "admin"

      html = view |> form("#promote-form", %{username: "nobody"}) |> render_submit()
      assert html =~ "Couldn&#39;t promote them."
    end
  end
end
