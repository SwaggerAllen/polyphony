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
  import Phoenix.LiveViewTest, only: [live_isolated: 2]

  require Logger

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

    test "the relay's own reply is logged, not just the fact of one" do
      user = user_fixture()

      # A 250 carries the provider's message id — Postmark's is what you search their
      # Activity feed by. It is the only thing that connects "we sent it" to what the
      # provider then did with it, and the trail is otherwise blind past our boundary.
      log =
        with_info_logs(fn ->
          Notifications.deliver(user, :magic_link, %{url: "x"},
            force: true,
            transport: __MODULE__.StubRelay
          )
        end)

      assert log =~ "250 OK; MessageID=abc-123"
    end

    test "an account with no email says so instead of going quiet" do
      # This branch returns before `dispatch/6`, so it used to log nothing — which
      # reads exactly like the send never having been attempted. There is no email
      # *verification* in this system, so a blank address is the only way an account
      # can be undeliverable, and it has to say so.
      log = with_info_logs(fn -> Notifications.deliver("", :magic_link, %{url: "x"}) end)

      assert log =~ "[mail] magic_link"
      assert log =~ "no email address"
    end

    test "an unrecognised notification type says so too" do
      log = with_info_logs(fn -> Notifications.deliver("a@b.io", :not_a_type, %{}) end)

      assert log =~ "[mail] not_a_type"
      assert log =~ "not a known notification type"
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

      %{css: File.read!(@built_css), markup: render_drawer()}
    end

    # The drawer went unstyled because its rules lived in a stylesheet that was
    # deleted, and nothing failed: the class names simply stopped matching anything.
    # Asserting against the *rendered markup* rather than a fixed list is what keeps
    # this honest — rename a class in the template and this still checks the new one.
    test "every kit class the drawer renders is defined in the kit", %{css: css, markup: markup} do
      kit_classes =
        ~w(dock dock-panel dock-tab sheet row pill dot scroller ttl lbl mono dim btn btn-sm btn-gh)

      for class <- kit_classes, String.contains?(markup, class) do
        assert css =~ ".#{class}", "the drawer renders .#{class} but the kit defines no rule"
      end
    end

    test "the dock lives in the kit, not a stylesheet of its own", %{css: css} do
      # The point of the rework: a floating panel is a position, not a second design
      # language. `mix kit.port` regenerates kit.css from ux/, so this also asserts the
      # primitive survived the port.
      assert File.read!("ux/polyphony-kit.css") =~ ".dock {"
      assert css =~ ~r/\.dock\s*\{[^}]*position:\s*fixed/
      refute File.exists?("assets/css/debug.css")
    end

    test "long unbroken tokens wrap instead of widening the panel" do
      # A magic-link URL is one long token; without this it forces horizontal scroll
      # on a phone and the rest of the log becomes unreadable.
      assert render_line(%{level: :info, message: "[mail] x"}) =~ "overflow-wrap:anywhere"
    end

    test "the panel is capped to the viewport, for a phone", %{css: css} do
      assert css =~ ~r/\.dock-panel\s*\{[^}]*width:\s*min\(100vw/
      assert css =~ ~r/\.dock-panel\s*\{[^}]*max-height:\s*min\(70vh/
      # A dock is opened one-handed; 44px is the smallest reliably tappable target.
      assert css =~ ~r/\.dock-tab\s*\{[^}]*min-height:\s*44px/
    end
  end

  describe "severity in the log" do
    test "a failed send reads as an error, not as one more mail line" do
      # Both an error and a [mail] line; severity has to win, or a failure hides in
      # the colour of the thing that was working.
      error_mail = render_line(%{level: :error, message: "[mail] FAILED"})

      assert error_mail =~ "var(--pencil)"
      refute error_mail =~ "var(--secret)"
    end

    test "an ordinary mail line is picked out of the stream" do
      assert render_line(%{level: :info, message: "[mail] sent"}) =~
               "var(--secret)"
    end
  end

  defmodule StubRelay do
    @moduledoc false
    @behaviour Polyphony.Notifications.Transport

    @impl true
    def deliver_email(_to, _subject, _body), do: {:ok, "250 OK; MessageID=abc-123\r\n"}
  end

  # Rendered through the real LiveView, so these assertions track the template rather
  # than a copy of it — and **isolated**, because the drawer is a sticky nested
  # LiveView and its stream does not render into the parent page's static HTML.
  defp render_drawer(entries \\ []) do
    # A `describe` setup may already have rendered once; starting twice is not an error.
    case start_supervised({Polyphony.DebugLog, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if entries != [] do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      capture_log(fn ->
        for e <- entries do
          if e.level == :error, do: Logger.error(e.message), else: Logger.info(e.message)
        end
      end)

      Process.sleep(120)
    end

    {:ok, _view, html} =
      live_isolated(Phoenix.ConnTest.build_conn(), PolyphonyWeb.DebugDrawerLive)

    html
  end

  defp render_line(entry), do: render_drawer([entry])
end
