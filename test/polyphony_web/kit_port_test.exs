defmodule PolyphonyWeb.KitPortTest do
  @moduledoc """
  The drift guard between the design kit and the shipped stylesheet.

  CLAUDE.md's convention is that `ux/polyphony-kit.css` is the single source of
  truth and screens port from it rather than re-deriving it. A convention alone
  drifts, so `mix kit.port` derives `assets/css/kit.css` mechanically and this
  test fails the build the moment the two disagree — whether because the design
  moved and nobody re-ran the task, or because someone hand-edited the generated
  file.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kit.Port, as: KitPort

  @source KitPort.source_path()
  @target KitPort.target_path()

  test "the committed stylesheet is exactly what the design kit ports to" do
    assert File.read!(@target) == @source |> File.read!() |> KitPort.port(),
           "#{@target} is stale — run `mix kit.port` and commit the result"
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

  test "component rules are confined to a frame root, in both positions" do
    ported = @source |> File.read!() |> KitPort.port()

    # A mock frame routinely carries a component class on the root element
    # (`class="fr stage dark sheet p-4"`), so each rule needs the descendant and
    # the self form.
    assert ported =~ ".fr .sheet,\n.fr.sheet {"
    assert ported =~ ".fr .btn-pri,\n.fr.btn-pri {"

    # Compound and combinator selectors keep their shape.
    assert ported =~ ".fr .sw-on i,\n.fr.sw-on i {"
    assert ported =~ ".fr .seg > *,\n.fr.seg > * {"
    assert ported =~ ".fr .beat-rule::after,\n.fr.beat-rule::after {"
  end

  test "register and token rules pass through unscoped" do
    ported = @source |> File.read!() |> KitPort.port()

    # These are already gated by the frame root's own classes; scoping them would
    # break `<div class="fr stage dark">`, where all three sit on one element.
    assert ported =~ "\n.fr {"
    assert ported =~ "\n.stage.dark {"
    assert ported =~ "\n.page.light {"
    refute ported =~ ".fr .stage"
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

  test "declaration bodies are carried across untouched" do
    source = File.read!(@source)
    ported = KitPort.port(source)

    # The port rewrites selectors only. Bodies — including the comments that
    # carry the design's reasoning — are the design's, verbatim.
    assert ported =~ "--pencil:#E0604A; --lamp:#EDB25E; --ok:#6FBF92; --secret:#9B8FD4;"
    assert ported =~ "The single most important idiom in the product"
    assert ported =~ "box-shadow:0 0 0 2px var(--b2), 0 0 0 3.5px var(--bc);"

    # No declaration is lost: the two files agree on how many there are.
    assert count(ported, ";") == count(strip_mock_chrome(source), ";")
  end

  defp classes(css), do: Regex.scan(~r/\.[a-z][a-z0-9-]*/, css) |> List.flatten() |> Enum.uniq()

  defp classes_below_mock_chrome(css) do
    case String.split(css, "MOCK CHROME", parts: 2) do
      [_, tail] -> classes(tail)
      _ -> []
    end
  end

  defp strip_mock_chrome(css) do
    css |> String.split("MOCK CHROME", parts: 2) |> hd()
  end

  defp count(haystack, needle), do: haystack |> :binary.matches(needle) |> length()
end
