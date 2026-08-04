defmodule PolyphonyWeb.SettingsScreenLiveTest do
  @moduledoc """
  Settings as `ux/polyphony-settings-auth.html` draws it.

  The load-bearing one: **the cap is a number you can change**, and the error copy has
  promised that for a long time with nothing behind it. The rest is about meeting the
  control before it bites you — turns remaining rather than a percentage, and where the
  money actually went, per campaign, which has never been shown anywhere.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Accounts, Costs, Library, Owner}
  alias Polyphony.Notifications.Prefs

  setup :register_and_log_in_user

  defp spend(user, campaign_id, amount) do
    Costs.record(%{
      user_id: user.id,
      campaign_id: campaign_id,
      amount: amount,
      kind: "generation"
    })
  end

  defp campaign(user, attrs \\ %{}) do
    payload = Map.merge(%{kind: :campaign, name: "The Salt Line", scenes: ["s1"]}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  describe "the cap" do
    test "raising it is one field, and the number binds afterwards", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      opened = view |> element("button[phx-click=edit_cap]") |> render_click()
      assert opened =~ "Your daily limit"

      view |> form("#cap-form", %{cap: "10.00"}) |> render_submit()

      reloaded = Accounts.get(user.id)
      assert reloaded.daily_cap == 1_000_000
      assert Costs.daily_cap(reloaded) == 1_000_000
    end

    test "a nonsense number says so instead of saving silently", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("button[phx-click=edit_cap]") |> render_click()

      html = view |> form("#cap-form", %{cap: "lots"}) |> render_submit()

      assert html =~ "didn&#39;t save"
      assert Accounts.get(user.id).daily_cap == nil
    end

    test "hitting it says what happened and that nothing was lost", %{conn: conn, user: user} do
      {:ok, _} = Accounts.set_daily_cap(user, 100)
      spend(user, "c1", 100)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "That&#39;s today&#39;s limit"
      assert html =~ "exactly where you left them."
    end

    test "getting close reads as turns, not as a percentage", %{conn: conn, user: user} do
      {:ok, _} = Accounts.set_daily_cap(user, 1_000)
      for _ <- 1..9, do: spend(user, "c1", 100)

      {:ok, _view, html} = live(conn, ~p"/settings")

      # 900 of 1000 spent, averaging 100 a turn — one more.
      assert html =~ "About one more turn at what today has cost."
      refute html =~ "90%"
    end

    test "comfortable says nothing at all about turns", %{conn: conn, user: user} do
      {:ok, _} = Accounts.set_daily_cap(user, 10_000)
      spend(user, "c1", 100)

      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "more turns at what today has cost"
    end
  end

  describe "where it went" do
    test "per campaign, with each row's own lifetime limit", %{conn: conn, user: user} do
      salt = campaign(user, %{name: "The Salt Line", spend_cap: 2_000_000})
      spend(user, to_string(salt.id), 1_400_000)
      spend(user, nil, 122_000)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Where it went"
      assert html =~ "The Salt Line"
      assert html =~ "$14.00"
      assert html =~ "Playing · $14.00 all time of $20.00"
      # Writing characters and worlds is its own row, not folded into a campaign.
      assert html =~ "Writing characters and worlds"
      assert html =~ "Outside any scene"
    end

    test "a campaign row links to where its own limit lives", %{conn: conn, user: user} do
      salt = campaign(user)
      spend(user, to_string(salt.id), 500)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "/campaigns/#{salt.id}"
    end
  end

  describe "you" do
    test "age is locked, because it's what having an account means", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Confirmed 18 or over"
      assert html =~ "Locked"
    end

    test "the name says when you can next change it", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "You can change this once a month."

      {:ok, _} = Accounts.change_username(user, "renamed")
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Next change available in"
    end

    test "no automated-analysis toggle, because there's nothing to toggle", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      refute html =~ "analysis"
      refute html =~ "proactive"
    end
  end

  describe "leaving" do
    test "the confirmation counts what goes rather than describing it", %{conn: conn, user: user} do
      campaign(user)
      campaign(user, %{name: "Low Water"})

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = view |> element("button[phx-click=confirm_delete]") |> render_click()

      assert html =~ "2 campaigns"
      assert html =~ "gone in 30 days"
      assert html =~ "keeps their copy"
      assert html =~ "Sign back in within 30 days"
    end

    test "asking destroys nothing and shows the clock", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("button[phx-click=confirm_delete]") |> render_click()
      html = view |> element("button[phx-click=delete_account]") |> render_click()

      assert html =~ "Your account goes in 30 days"
      assert Accounts.get(user.id) != nil
      # The delete button is gone while the clock runs — nothing to press twice.
      refute html =~ "phx-click=\"confirm_delete\""
    end

    test "changing your mind stops it", %{conn: conn, user: user} do
      {:ok, _} = Accounts.request_deletion(user)

      {:ok, view, html} = live(conn, ~p"/settings")
      assert html =~ "Your account goes in 30 days"

      view |> element("button[phx-click=cancel_delete]") |> render_click()
      assert Accounts.get(user.id).deletion_requested_at == nil
    end
  end

  describe "notification preferences" do
    test "are reachable, and default to on", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      # §B4's prefs existed as rows nobody could reach: `Prefs` shipped with the
      # notification path and no screen ever rendered it.
      assert html =~ "Replies to you"
      assert html =~ ~s(phx-click="toggle_notification")
      # Opt-out: absence of a row is consent, so everything starts on.
      assert html =~ "sw-on"
    end

    test "turning one off writes the row, and it survives a reload",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element(~s([phx-click="toggle_notification"][phx-value-type="subscription"]))
      |> render_click()

      refute Prefs.wants?(user.id, :subscription)
      # And the others are untouched — one switch, one type.
      assert Prefs.wants?(user.id, :comment_reply)

      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Campaigns you follow"
    end

    test "sign-in links are not offered as a preference", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")

      # It is the only way into the account. A switch that can lock you out of your own
      # sign-in is not a preference — `Notifications` forces it past prefs for the same
      # reason, so offering it here would be a lie about what the switch does.
      refute html =~ ~s(phx-value-type="magic_link")
      assert html =~ "Sign-in links always arrive"
    end
  end
end
