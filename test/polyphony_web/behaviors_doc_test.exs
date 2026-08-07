defmodule PolyphonyWeb.BehaviorsDocTest do
  @moduledoc """
  Every screen has a behaviors doc, and its states are the storybook's states.

  `docs/behaviors/<screen>.md` is what the design thread reads and designs against
  (`docs/design-thread.md`), and a design proposed against a stale description is worse
  than one proposed against nothing — it arrives looking correct. Prose can't be
  type-checked, but the *set of states* can, and that is the part that rots: a state gets
  added to a screen and nobody writes the paragraph, or a paragraph outlives the state it
  described.

  So each `### \\`id\\`` heading in a behaviors file names a storybook variation, and the
  two sets must match exactly. What the paragraph says is still on the author; that it
  exists, and that nothing it describes has been deleted, is on this.

  The `rev` line is checked for presence only. It is provenance — the design thread quotes
  the rev it read — and nothing here can tell whether somebody remembered to bump it.
  """
  use ExUnit.Case, async: true

  @dir "docs/behaviors"

  # `Screens.SheetEditor` -> `sheet_editor`, which is also the story filename.
  defp slug(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp screens do
    :code.all_available()
    |> Enum.map(fn {mod, _, _} -> to_string(mod) end)
    |> Enum.filter(&String.starts_with?(&1, "Elixir.PolyphonyWeb.Screens."))
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.sort()
  end

  defp story(screen) do
    Module.concat([Storybook.Screens, screen |> Module.split() |> List.last()])
  end

  # `### \`stage\` — Omniscient play` -> "stage". Only headings at this level count, so a
  # backticked identifier inside a paragraph is not mistaken for a state.
  defp documented_states(body) do
    ~r/^### `([a-z0-9_?]+)`/m
    |> Regex.scan(body)
    |> Enum.map(&List.last/1)
  end

  test "every screen has a behaviors doc" do
    assert screens() != [], "no screen modules found — has PolyphonyWeb.Screens.* moved?"

    for screen <- screens() do
      path = Path.join(@dir, "#{slug(screen)}.md")

      assert File.exists?(path),
             "#{inspect(screen)} has no behaviors doc — add #{path} (see #{@dir}/README.md)"
    end
  end

  test "every behaviors doc carries a rev line" do
    for path <- Path.wildcard("#{@dir}/*.md") do
      assert File.read!(path) =~ ~r/^<!-- rev: \d+ -->$/m,
             "#{path} has no `<!-- rev: n -->` line — the design thread cites it as provenance"
    end
  end

  test "a doc's states are exactly its screen's storybook variations" do
    for screen <- screens() do
      path = Path.join(@dir, "#{slug(screen)}.md")
      documented = documented_states(File.read!(path))

      built =
        screen
        |> story()
        |> then(&Enum.map(&1.variations(), fn v -> to_string(v.id) end))

      assert Enum.sort(documented) == Enum.sort(built), """
      #{path} and its storybook story disagree about which states exist.

      Only in the doc:       #{inspect(documented -- built)}
      Only in the storybook: #{inspect(built -- documented)}

      Each `### `id`` heading names a variation. Add the missing paragraph, or drop the
      one describing a state nobody can look at.
      """
    end
  end

  test "every doc is listed in the behaviors README, so the index can't go quiet" do
    readme = File.read!(Path.join(@dir, "README.md"))

    for path <- Path.wildcard("#{@dir}/*.md"), Path.basename(path) != "README.md" do
      assert readme =~ "`#{Path.basename(path)}`",
             "#{path} is not named in #{@dir}/README.md"
    end
  end
end
