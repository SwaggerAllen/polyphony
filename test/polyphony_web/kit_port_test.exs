defmodule PolyphonyWeb.KitPortTest do
  @moduledoc """
  The drift guard between the design kit and the shipped stylesheet.

  CLAUDE.md's convention is that `ux/polyphony-kit.css` is the single source of
  truth and screens port from it rather than re-deriving it. A convention alone
  drifts, so `mix kit.port` derives `assets/css/kit.css` mechanically and this
  test fails the build the moment the two disagree — whether because the design
  moved and nobody re-ran the task, or because someone hand-edited the generated
  file.

  The port is a **copy**, not an adaptation: the app's stylesheet is the design's,
  so a class means the same thing in both. The only thing dropped is the kit's §11
  mock chrome, which styles the wall labels *around* the mock frames. That's what
  the assertions below pin — everything else surviving byte for byte.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kit.Port, as: KitPort

  @source KitPort.source_path()
  @target KitPort.target_path()

  test "the committed stylesheet is exactly what the design kit ports to" do
    assert File.read!(@target) == @source |> File.read!() |> KitPort.port(),
           "#{@target} is stale — run `mix kit.port` and commit the result"
  end

  test "the jump bar is pinned, because two screens describe it as one" do
    css = File.read!(@target)

    # `BibleEditorLive` and `SheetEditorLive` both call it "a sticky `Kit.jump`" and
    # it never was: the class carried no positioning at all, so on a document that
    # scrolls it left with the page. Both screens are one long scroll by design — no
    # accordions — which makes this the only navigation they have, and navigation you
    # have to scroll back to reach is not navigation.
    [rule] = Regex.run(~r/^\.jump \{.*?\}/ms, css) |> List.wrap()

    assert rule =~ "position:sticky"
    assert rule =~ "top:0"
    # And a background, or the content scrolls through it.
    assert rule =~ "background:var(--b2)"
  end

  test "everything above the mock chrome survives byte for byte" do
    source = File.read!(@source)
    ported = KitPort.port(source)

    # Strip the generated header and what's left must be the design file itself,
    # truncated at the §11 banner. No rewritten selectors, no reordering, no
    # reformatting — if this ever needs relaxing, the kit has stopped being the
    # source of truth and something else has become one.
    [_header, body] = String.split(ported, "============================ */\n\n", parts: 2)

    assert body == mock_chrome_stripped(source)
  end

  test "mock chrome never reaches the app" do
    ported = @source |> File.read!() |> KitPort.port()

    # §11 styles the wall labels around the mock frames, not the product. Its
    # bare element selectors would leak into every page if they came along.
    refute ported =~ "MOCK CHROME"
    refute ported =~ ~r/^body\s/m
    refute ported =~ ~r/^:root\s/m
    refute ported =~ ~r/^h2\s/m
    refute ported =~ ".wall"
  end

  test "component rules stay global, exactly as the mocks write them" do
    ported = @source |> File.read!() |> KitPort.port()

    # The kit was briefly scoped to a `.fr` root so it could coexist with the
    # first-cut design system. It isn't any more — the kit wins those collisions
    # outright — and a scoped selector reappearing means someone reintroduced a
    # compatibility layer the design doesn't have.
    refute ported =~ ".fr .sheet"
    refute ported =~ ".fr.sheet"

    assert ported =~ ~r/^\.sheet\s/m
    assert ported =~ ~r/^\.btn\s/m
    assert ported =~ ~r/^\.row\s/m
  end

  test "every class the design kit defines survives the port" do
    source = File.read!(@source)
    ported = KitPort.port(source)

    kit_classes = classes(source) -- classes_below_mock_chrome(source)

    for class <- kit_classes do
      assert ported =~ class, "#{class} was dropped by the port"
    end

    # A sanity floor: the kit is a real component library, not three rules.
    assert length(kit_classes) > 50
  end

  test "the kit is loaded last, and is the only design system left" do
    app = File.read!("assets/css/app.css")
    imports = app |> then(&Regex.scan(~r/@import "\.\/(.+)\.css"/, &1)) |> Enum.map(&List.last/1)

    # app.css is an ordered manifest and the order is the point: Tailwind, then the
    # kit, so the kit outranks a utility it overlaps with. A third entry means a
    # second design system came back — including for internal surfaces: the debug
    # drawer is built from kit classes over the kit's own `.dock`, not a stylesheet
    # of its own.
    assert imports == ["tailwind-full", "kit"]
    refute File.exists?("assets/css/legacy.css")
    refute File.exists?("assets/css/debug.css")
  end

  defp classes(css), do: Regex.scan(~r/\.[a-z][a-z0-9-]*/, css) |> List.flatten() |> Enum.uniq()

  defp classes_below_mock_chrome(css) do
    case String.split(css, "MOCK CHROME", parts: 2) do
      [_, tail] -> classes(tail)
      _ -> []
    end
  end

  # The design file up to (but not including) the banner comment that opens §11.
  defp mock_chrome_stripped(source) do
    at = :binary.match(source, "MOCK CHROME") |> elem(0)
    {cut, _} = source |> binary_part(0, at) |> :binary.matches("/*") |> List.last()

    String.trim_trailing(binary_part(source, 0, cut)) <> "\n"
  end
end
