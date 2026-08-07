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

  test "no screen reads domain data" do
    # The property that makes `STORYBOOK=true` safe in production. A screen takes assigns
    # and returns markup; a story that could load a campaign would quietly turn that flag
    # into an authorization hole.
    #
    # The question is **can this reach the database**, not "does this call `Polyphony.*`".
    # Those look alike and are not: `Library.payload/1` is `decode(bin)` and
    # `Cast.render_name/2` is a `Map.get`, while `Audience.resolve/1` walks through
    # `Groups.member_ids/2` to the repo. `Polyphony.Test.Purity` computes the difference
    # from the call graph, so nothing here is exempted by hand — an earlier version kept a
    # growing allowlist of functions somebody had read once and pronounced safe.
    impure = Polyphony.Test.Purity.impure()

    for mod <- screen_modules() do
      offenders =
        mod
        |> domain_calls()
        |> Enum.filter(&MapSet.member?(impure, &1))
        |> Enum.uniq()

      assert offenders == [],
             "#{inspect(mod)} can reach the database via #{inspect(offenders)} — a screen " <>
               "renders from assigns alone. Do the read in the LiveView and pass the answer in."
    end
  end

  test "no screen dispatches dynamically, which is what makes the check above sound" do
    # A static call graph cannot see through `apply/3`, a protocol, or a module held in a
    # variable — an impure function reached that way would pass the guard. Rather than
    # accept that hole, close it from the other side: a screen is markup and has no
    # business dispatching dynamically, so any occurrence is a failure.
    #
    # This is not hypothetical in general — the domain does it constantly, because the
    # repo is injectable (`repo(opts)` then `repo.all(q)`). It is what made the first run
    # of the analysis call `Library.get/1` pure. It just has no place on a screen.
    for mod <- screen_modules() do
      dynamic = for {:dynamic, _, _} = d <- all_calls(mod), do: d

      assert dynamic == [],
             "#{inspect(mod)} dispatches dynamically (#{inspect(dynamic)}). The purity " <>
               "check cannot see through that, so a screen may not do it."
    end
  end

  defp screen_modules do
    for {mod, _, _} <- :code.all_available(),
        name = to_string(mod),
        String.starts_with?(name, "Elixir.PolyphonyWeb.Screens."),
        name != "Elixir.PolyphonyWeb.Screens",
        do: String.to_atom(name)
  end

  # Every `Polyphony.*` (but not `PolyphonyWeb.*`) call a compiled module makes, as MFAs.
  defp domain_calls(mod) do
    Enum.filter(all_calls(mod), fn {m, _f, _a} ->
      name = to_string(m)

      String.starts_with?(name, "Elixir.Polyphony.") and
        not String.starts_with?(name, "Elixir.PolyphonyWeb.")
    end)
  end

  # Read off the **abstract code**, not the `:imports` chunk. A call on a module held in
  # a variable leaves no trace in imports at all — not even an `:erlang.apply/3` — so a
  # check built on that chunk silently passes the one thing it exists to catch.
  defp all_calls(mod) do
    Code.ensure_loaded!(mod)
    Polyphony.Test.Purity.calls_in(mod)
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
