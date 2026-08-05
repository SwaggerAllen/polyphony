defmodule PolyphonyWeb.HomeScreenLiveTest do
  @moduledoc """
  The landing page — the only screen a stranger sees before deciding whether to sign up.

  What it has to get across is the thing that doesn't survive a screenshot: the
  characters don't know what you know. World bibles and arcs explain themselves once
  you're inside; the filtered projection is the reason to be here and is invisible
  unless the page shows it happening. So the middle of the page is a transcript drawn
  with the kit's own transcript components, attribution line included, and what is
  pinned here is that the demonstration and both ways in are actually on it.
  """
  use PolyphonyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "signed out" do
    test "explains what this is before asking for anything", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Write a world, cast some people"
      # The claim itself, in a sentence rather than a feature name.
      assert html =~ "knows only what"
      assert html =~ "How it goes"
    end

    test "shows the guarantee rather than describing it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # `Kit.thought/1`'s attribution line is the visibility guarantee made legible, and
      # it is the same component play draws — a stranger reads the real thing.
      assert html =~ "m-thought"
      assert html =~ "Thought · only Wren"
      assert html =~ "was never given that first paragraph"
    end

    test "both ways in, twice — the top of the page and the bottom", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert length(Regex.scan(~r|href="/signup"|, html)) == 2
      assert length(Regex.scan(~r|href="/login"|, html)) == 2
      assert html =~ ~s(href="/browse")
      # Magic links are the whole sign-in flow, so the page says so before the click.
      assert html =~ "No password to remember"
    end
  end

  describe "signed in" do
    setup :register_and_log_in_user

    test "is a way back to the library, not a pitch", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(href="/library")
      # Nobody needs to be sold the product they are already using.
      refute html =~ ~s(href="/signup")
      refute html =~ "Start with one sentence"
    end
  end
end
