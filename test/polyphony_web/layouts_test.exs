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

    test "a signed-out visitor is offered the way in, and no menu", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Sign in"
      assert html =~ "Create an account"
      # The nav menu is for a signed-in user's own things; there's nothing in it for a
      # visitor, so it isn't drawn at all.
      refute html =~ "Sign out"
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
end
