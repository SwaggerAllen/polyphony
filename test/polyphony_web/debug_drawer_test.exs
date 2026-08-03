defmodule PolyphonyWeb.DebugDrawerTest do
  @moduledoc """
  The debug drawer as a diagnostic tool: the mail trail it carries, and the styles
  that make it usable on a phone.

  Both halves are regression tests for things that had already gone wrong. The mail
  path could report success without sending anything and said nothing about which
  transport ran, so an empty inbox had no explanation visible from a device you can't
  attach a console to. And the drawer's stylesheet was lost with the first-cut design
  system, leaving it an unstyled block — silently, because nothing referenced those
  class names any more.
  """
  use PolyphonyWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Polyphony.Notifications

  @built_css "priv/static/assets/app.css"

  defp with_info_logs(fun) do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    capture_log(fun)
  end

  describe "the mail trail" do
    test "a send names the transport that ran" do
      user = user_fixture()

      log =
        with_info_logs(fn ->
          Notifications.deliver(user, :magic_link, %{url: "x"}, force: true)
        end)

      # The single most useful fact on the screen: `Transport.Log` reports success
      # without sending anything, so naming it *is* the answer to "why is my inbox
      # empty". A line that only said "sent" would be actively misleading.
      assert log =~ "[mail] magic_link"
      assert log =~ "sent via"
      assert log =~ "Transport.Log"
    end

    test "a failure says why, at error level" do
      user = user_fixture()

      log =
        with_info_logs(fn ->
          Notifications.deliver(user, :magic_link, %{url: "x"},
            force: true,
            transport: Polyphony.Notifications.Transport.Email
          )
        end)

      # No :mail_from configured in test, so the Email transport refuses.
      assert log =~ "FAILED"
      assert log =~ "no_from_address"
      assert log =~ "[error]"
    end

    test "addresses are masked — the drawer is not admin-gated" do
      user = user_fixture(%{email: "someone@example.com"})

      log =
        with_info_logs(fn ->
          Notifications.deliver(user, :magic_link, %{url: "x"}, force: true)
        end)

      assert log =~ "s***@example.com"
      refute log =~ "someone@example.com"
    end

    test "the sign-in token is fingerprinted, never logged whole" do
      user = user_fixture()
      token = PolyphonyWeb.Auth.sign_token(user.id)

      log = with_info_logs(fn -> PolyphonyWeb.Auth.deliver_magic_link(user) end)

      assert log =~ "magic_link requested for user ##{user.id}"

      # The request line carries only a prefix. A live 15-minute token in a stream any
      # visitor can read while DEBUG_DRAWER is on would be the same account-takeover
      # hole the login screen's on-page link was — and the drawer can't be admin-gated,
      # because its most valuable use is diagnosing sign-in while signed out.
      [request_line] =
        log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "magic_link requested"))

      refute request_line =~ token
      assert request_line =~ String.slice(token, 0, 8)
    end
  end

  describe "the drawer's styles" do
    setup do
      assert File.exists?(@built_css),
             "run `mix assets.build` — the committed bundle is what the app serves"

      %{css: File.read!(@built_css)}
    end

    # The drawer went unstyled because its rules lived in a stylesheet that was
    # deleted, and nothing failed: the class names simply stopped matching anything.
    # This is the check that would have caught it.
    test "every structural class the markup uses is defined", %{css: css} do
      for class <- ~w(
            debug-drawer debug-drawer-body debug-drawer-head debug-drawer-toggle
            debug-title debug-count debug-empty debug-log-list
            debug-line debug-time debug-lvl debug-msg
            socket-status socket-dot
          ) do
        assert css =~ ".#{class}", "no rule for .#{class} in #{@built_css}"
      end
    end

    test "the panel lays out as a column, since app.js owns `display`", %{css: css} do
      # app.js toggles display none ⇄ flex so the drawer works with no socket. If the
      # stylesheet set `display` too it would fight that; the direction must still be
      # declared or the head and log stack sideways.
      assert css =~ ~r/\.debug-drawer-body\s*\{[^}]*flex-direction:\s*column/
      refute css =~ ~r/\.debug-drawer-body\s*\{[^}]*[^-]display:/
    end

    test "long unbroken tokens wrap instead of widening the panel", %{css: css} do
      # A magic-link URL is one long token; without this it forces horizontal scroll
      # on a phone and the rest of the log becomes unreadable.
      assert css =~ ~r/\.debug-msg\s*\{[^}]*overflow-wrap:\s*anywhere/
    end

    test "severity outranks the mail tint, so a failed send reads as an error", %{css: css} do
      # Same specificity, so source order decides: .mail must come first.
      mail = :binary.match(css, ".debug-line.mail .debug-msg") |> elem(0)
      error = :binary.match(css, ".debug-line.lvl-error") |> elem(0)

      assert mail < error, "the .mail rule must precede the level colours"
    end
  end
end
