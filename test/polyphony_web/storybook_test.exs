defmodule PolyphonyWeb.StorybookTest do
  @moduledoc """
  Every story in the catalogue renders.

  A storybook is only a drift guard if it works, and a broken story is easy not
  to notice — nothing else in the app references it. So the suite walks the
  catalogue and renders each entry, which fails on a story that doesn't compile,
  a variation whose attributes no longer match the component, or a component that
  was renamed out from under it.

  It also pins the pairing the whole port rests on: every kit component has a
  story. A component with no page in the catalogue is one whose states will
  quietly diverge from the design.
  """
  use PolyphonyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @backend PolyphonyWeb.Storybook

  test "the catalogue is mounted, and lands on the page that explains it", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/storybook/welcome"}}} = live(conn, "/storybook")

    {:ok, _view, html} = live(conn, "/storybook/welcome")

    assert html =~ "single source of truth"
  end

  test "every story renders", %{conn: conn} do
    leaves = @backend.leaves()

    assert leaves != [], "the storybook found no stories — check :content_path"

    for leaf <- leaves do
      assert {:ok, _view, _html} = live(conn, "/storybook#{leaf.path}"),
             "story #{leaf.path} failed to render"
    end
  end

  test "every kit component has a page in the catalogue" do
    catalogued =
      for leaf <- @backend.leaves(),
          {:ok, story} = @backend.load_story(String.trim_leading(leaf.path, "/")),
          story.storybook_type() == :component,
          into: MapSet.new(),
          do: story.function()

    for {name, arity} <- PolyphonyWeb.Kit.__info__(:functions),
        arity == 1,
        not String.starts_with?(to_string(name), "__") do
      component = Function.capture(PolyphonyWeb.Kit, name, 1)

      assert component in catalogued,
             "PolyphonyWeb.Kit.#{name}/1 has no story — add one under storybook/kit/"
    end
  end
end
