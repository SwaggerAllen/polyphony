defmodule PolyphonyWeb.LayoutsTest do
  @moduledoc """
  The app shell: a document that has colours, and no standing navigation.

  Two things are worth pinning because both are easy to undo by reflex. The
  register lives on `<body>`, which is the only reason anything outside a screen's
  own frame has tokens at all — remove it and every page renders on browser-default
  white with the kit's colours resolving to nothing. And there is no global nav bar:
  the design gives a screen the whole viewport and puts everywhere-else behind the
  header's `☰`, so a nav bar creeping back would cost a row on every screen and break
  the play view's viewport-height layout.
  """
  use PolyphonyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "the document" do
    test "the body is a frame root, so the kit's tokens resolve", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(<body class="fr stage dark)
      # The three faces do semantic work (Spectral names things), so they're loaded.
      assert html =~ "family=Spectral"
    end
  end

  describe "navigation" do
    test "there is no standing nav bar", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "topbar"
      refute html =~ "nav-links"
    end

    test "a signed-out visitor is offered the way in", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Sign in"
      assert html =~ "Create an account"
      refute html =~ "Sign out"
    end

    test "a visitor on a public screen can still get somewhere", %{conn: conn} do
      # `/browse` and a shared story are reachable signed out, and their header used to
      # carry no menu at all — no way to the page that explains what you're reading, no
      # way to sign in, no way to make an account. Somebody who arrived on a shared link
      # is the person with the most reason to be offered all three.
      {:ok, _view, html} = live(conn, ~p"/browse")

      assert html =~ ~s(aria-label="Menu")
      assert html =~ "What Polyphony is"
      assert html =~ ~s(href="/login")
      assert html =~ ~s(href="/signup")
      refute html =~ "Sign out"
    end

    test "the landing page is reachable from the sign-in and sign-up screens",
         %{conn: conn} do
      # The wordmark goes home, which is the convention every site has — and the only
      # route out for someone who arrived on a bookmark or an invite and wants to read
      # what they're signing into.
      for path <- [~p"/login", ~p"/signup"] do
        {:ok, _view, html} = live(conn, path)
        assert html =~ ~s(href="/" data-phx-link), "no way home from #{path}"
      end
    end
  end

  describe "the nav menu" do
    setup :register_and_log_in_user

    test "carries everywhere that isn't this screen", %{conn: conn} do
      scene = open_scene()

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ "Your stuff"
      assert html =~ "Settings"
      assert html =~ "Sign out"
      # It opens without JavaScript: a menu holding sign-out shouldn't need a live
      # connection to work.
      assert html =~ "<details"
    end

    test "it is a hamburger, and set apart from the controls beside it", %{conn: conn} do
      scene = open_scene()

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      # `⋯` means "the overflow of the thing I'm next to". Used for global navigation,
      # in a header that also carries a viewer picker, it reads as belonging to that
      # picker. The margin is the same point in space.
      assert html =~ ~s(aria-label="Menu">☰</summary>)
      assert html =~ ~s(<details class="relative ml-2)
    end

    test "it carries the landing page too, which nothing else linked to", %{conn: conn} do
      scene = open_scene()

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      # There was a landing page and no way to navigate to it from anywhere in the app.
      assert html =~ "What Polyphony is"
      assert html =~ ~s(href="/" data-phx-link)
    end

    test "admin is offered only to an admin", %{conn: conn} do
      scene = open_scene()

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")
      refute html =~ "Admin"

      admin_conn = build_conn() |> log_in_user(user_fixture(%{role: "superadmin"}))
      {:ok, _view, html} = live(admin_conn, ~p"/play/#{scene}")
      assert html =~ "Admin"
    end
  end

  defp open_scene do
    scene = "shell-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = Polyphony.App.dispatch(%Polyphony.Commands.OpenScene{scene_id: scene, opened_beat: 0})
    scene
  end

  describe "a flash you can get out of" do
    setup :register_and_log_in_user

    test "carries a visible dismiss, and is bounded", %{conn: conn} do
      scene = open_scene()
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

      html = render_click(view, "add_to_scene", %{"id" => "nobody"})
      assert html =~ "aren&#39;t available to bring in"

      # "Click it anywhere" is a real gesture and an invisible one. An error somebody
      # has to read is exactly the one they will look at for a control and not find.
      assert html =~ ~s(aria-label="Dismiss")
      assert html =~ "✕"

      # And the region can't grow over the screen it is reporting on: a bring-up build
      # with `:show_error_details` on can put a long message here, and a `fixed top-0`
      # box with no ceiling covers the controls you would use to get out.
      assert html =~ "max-h-[50dvh]"
      assert html =~ "overflow-y-auto"
    end

    test "and the dismiss actually clears it", %{conn: conn} do
      scene = open_scene()
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

      render_click(view, "add_to_scene", %{"id" => "nobody"})
      cleared = render_click(view, "lv:clear-flash", %{"key" => "error"})

      refute cleared =~ "aren&#39;t available to bring in"
    end
  end
end
