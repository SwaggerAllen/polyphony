defmodule PolyphonyWeb.BrowseAccessLiveTest do
  @moduledoc """
  Browse is the app's one public reading surface, and both ways it could be opened too
  far were open at once. Both are pinned here because neither would announce itself: a
  reader sees a story either way, and the difference is only whether they were meant to.

  **An unlisted story was readable by id.** `unlisted` means *reachable by the link*,
  and the reader's grant — the share token — was dropped at the hand-off from
  `/s/:token`, so the screen on the far side had nothing to check and stopped checking.
  Ids here are small integers.

  **Taking a copy asked nothing at all.** `take_world` reads its id from a
  `phx-value-id`, which is to say from the client, and copied the entry whole. Any
  signed-in account could lift a private world — secrets and all — out of somebody
  else's library by naming it. `CampaignLive.attach_world/2` had already worked out that
  attaching-is-copying needs a check; this path never got one.

  Both are one defect: the rule lived in four places and the copy that checked the token
  was the copy nobody called.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Library.Snapshot

  setup :register_and_log_in_user

  defp snapshot(attrs \\ %{}) do
    Snapshot.build(
      Map.merge(
        %{
          campaign_id: "camp",
          publication: %{perspectives: [], spectator: true},
          bible: %WorldBible{name: "The Ninth Gate", cover: "A city with no sky."},
          scenes: [],
          characters: []
        },
        attrs
      )
    )
  end

  defp story(author, visibility) do
    Library.put(%{
      owner: Owner.of(author),
      kind: "campaign",
      visibility: to_string(visibility),
      frozen: true,
      payload: snapshot()
    })
  end

  describe "an unlisted story" do
    test "does not open to a reader who names it without the link", %{conn: conn} do
      entry = story(user_fixture(), :unlisted)

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: entry.id]}")

      refute html =~ "A city with no sky."
      # The same answer an unpublished story gives. A distinct "you need the link" would
      # confirm that this id is a story somebody shared, which is the fact being kept.
      assert html =~ "This link doesn&#39;t lead anywhere any more."
    end

    test "opens to a reader holding the link", %{conn: conn} do
      entry = story(user_fixture(), :unlisted)

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: entry.id, t: entry.share_token]}")

      assert html =~ "A city with no sky."
    end

    test "opens through its share link, which is what the token is for", %{conn: conn} do
      entry = story(user_fixture(), :unlisted)

      # `/s/:token` hands a frozen campaign to Browse rather than rendering a second
      # reading view. The grant has to survive that hop or the flow the token exists to
      # serve is the one this fix breaks.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/s/#{entry.share_token}")
      assert to =~ "t=#{entry.share_token}"

      {:ok, _view, html} = live(conn, to)
      assert html =~ "A city with no sky."
    end

    test "opens to its own author, who holds no link to themselves", %{conn: conn, user: me} do
      entry = story(me, :unlisted)

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: entry.id]}")

      assert html =~ "A city with no sky."
    end

    test "a wrong token is no token", %{conn: conn} do
      entry = story(user_fixture(), :unlisted)

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: entry.id, t: "not-it"]}")

      refute html =~ "A city with no sky."
    end
  end

  describe "a public story" do
    test "opens to anyone, with no token in sight", %{conn: conn} do
      entry = story(user_fixture(), :public)

      {:ok, _view, html} = live(conn, ~p"/browse?#{[story: entry.id]}")

      assert html =~ "A city with no sky."
    end
  end

  describe "taking a copy" do
    test "refuses a private world named by id", %{conn: conn, user: me} do
      secret =
        Library.put(%{
          owner: Owner.of(user_fixture()),
          kind: "world_bible",
          visibility: "private",
          payload: %WorldBible{name: "Saltmarch", setting: "THE SECRET INTERNALS"}
        })

      {:ok, view, _html} = live(conn, ~p"/browse?tab=worlds")

      html = render_click(view, "take_world", %{"id" => to_string(secret.id)})

      assert html =~ "That isn&#39;t yours to take."
      assert Library.list_for_owner(Owner.of(me)) == []
    end

    test "refuses a private campaign named by id", %{conn: conn, user: me} do
      # Same hole, bigger payload: a live campaign carries its whole authored state.
      private = story(user_fixture(), :private)

      {:ok, view, _html} = live(conn, ~p"/browse?tab=worlds")

      render_click(view, "take_world", %{"id" => to_string(private.id)})

      assert Library.list_for_owner(Owner.of(me)) == []
    end

    test "allows a public world, which is the flow the screen is for", %{conn: conn, user: me} do
      shared =
        Library.put(%{
          owner: Owner.of(user_fixture()),
          kind: "world_bible",
          visibility: "public",
          payload: %WorldBible{name: "Saltmarch", cover: "A port town that runs on tides."}
        })

      {:ok, view, _html} = live(conn, ~p"/browse?tab=worlds")

      html = render_click(view, "take_world", %{"id" => to_string(shared.id)})

      assert html =~ "A copy is in your library."
      assert [copy] = Library.list_for_owner(Owner.of(me))
      assert Library.payload(copy).name == "Saltmarch"
    end

    test "allows an unlisted world to a reader holding its link", %{conn: conn, user: me} do
      # Taking a copy of what you may read is the product (§2.5b), so the bar is
      # `can_view?` rather than ownership — and a share link is a read grant.
      shared =
        Library.put(%{
          owner: Owner.of(user_fixture()),
          kind: "world_bible",
          visibility: "unlisted",
          payload: %WorldBible{name: "Saltmarch"}
        })

      {:ok, view, _html} = live(conn, ~p"/browse?#{[tab: "worlds", t: shared.share_token]}")

      render_click(view, "take_world", %{"id" => to_string(shared.id)})

      assert [copy] = Library.list_for_owner(Owner.of(me))
      assert Library.payload(copy).name == "Saltmarch"
    end
  end
end
