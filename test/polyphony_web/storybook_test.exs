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

  test "every screen has a story, so no screen is unreviewable" do
    # The kit rule, one level up. A screen component exists *in order* to be renderable
    # from fixtures — that is the whole reason its markup was lifted out of the LiveView —
    # so one without a story is a screen whose states can only be seen by driving the
    # real app into them, which is the thing this was built to stop.
    catalogued =
      for leaf <- @backend.leaves(),
          {:ok, story} = @backend.load_story(String.trim_leading(leaf.path, "/")),
          story.storybook_type() == :component,
          into: MapSet.new(),
          do: story.function()

    screens =
      :code.all_available()
      |> Enum.map(fn {mod, _, _} -> to_string(mod) end)
      |> Enum.filter(&String.starts_with?(&1, "Elixir.PolyphonyWeb.Screens."))
      |> Enum.map(&String.to_atom/1)

    assert screens != [], "no screen modules found — has PolyphonyWeb.Screens.* moved?"

    for screen <- screens do
      Code.ensure_loaded!(screen)

      assert function_exported?(screen, :screen, 1),
             "#{inspect(screen)} must expose screen/1 — that is the contract a story renders"

      assert Function.capture(screen, :screen, 1) in catalogued,
             "#{inspect(screen)} has no story — add one under storybook/screens/"
    end
  end

  # Pure display resolvers a screen may call, by **function** rather than by module.
  #
  # `Polyphony.Scene.Cast` is the id↔name resolver the whole codebase renders through:
  # `character_id` is the routing key and a name is display, resolved at the edges — and
  # a screen *is* an edge. `render_name/2` is a `Map.get` over a struct already sitting in
  # assigns, with an identity fallback, so a story renders it from a fixture.
  #
  # The granularity is the point. Allowing the *module* would also allow `Cast.of/1`,
  # which reads the event store; allowing the function allows exactly the pure lookup.
  @pure_display [
    {Polyphony.Scene.Cast, :render_name, 2},
    {Polyphony.Scene.Cast, :render_names, 2}
  ]

  test "no screen reads domain data" do
    # The property that makes `STORYBOOK=true` safe in production. A screen takes assigns
    # and returns markup; a story that could load a campaign would quietly turn the flag
    # into an authorization hole. Checked structurally rather than trusted, because the
    # tempting shortcut — resolving a name inside the markup — is exactly how it breaks.
    # It already had, once: play's character picker called `Library.payload/1` per row.
    for {mod, _, _} <- :code.all_available(),
        name = to_string(mod),
        String.starts_with?(name, "Elixir.PolyphonyWeb.Screens.") do
      mod = String.to_atom(name)
      Code.ensure_loaded!(mod)

      offenders =
        mod
        |> domain_calls()
        |> Enum.reject(&(&1 in @pure_display))
        |> Enum.uniq()

      assert offenders == [],
             "#{inspect(mod)} calls #{inspect(offenders)} — a screen must render from " <>
               "assigns alone. Resolve it in the LiveView and pass the answer in."
    end
  end

  # Every `Polyphony.*` (but not `PolyphonyWeb.*`) call a compiled module makes, as MFAs,
  # read off its BEAM imports chunk rather than off the source.
  defp domain_calls(mod) do
    case :beam_lib.chunks(:code.which(mod), [:imports]) do
      {:ok, {_, [imports: imports]}} ->
        Enum.filter(imports, fn {m, _f, _a} ->
          name = to_string(m)

          String.starts_with?(name, "Elixir.Polyphony.") and
            not String.starts_with?(name, "Elixir.PolyphonyWeb.")
        end)

      _ ->
        []
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
