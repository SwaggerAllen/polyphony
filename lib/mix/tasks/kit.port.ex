defmodule Mix.Tasks.Kit.Port do
  @moduledoc """
  Port `ux/polyphony-kit.css` into `assets/css/kit.css`.

  The design kit is the single source of truth for tokens and component classes
  (see CLAUDE.md conventions). Rather than hand-copying it — which is how design
  and implementation drift apart — this task *derives* the app stylesheet from
  the design file, and `KitPortTest` fails the build if the committed output stops
  matching. Editing the kit means editing `ux/` and re-running this task; there is
  nothing to hand-maintain on the app side.

  ## The transform

  One change, and deliberately no others: **drop §11 "mock chrome"**. The kit's last
  section styles the wall labels and notes *around* the mock frames (`body`, `:root`,
  `.wall`, `.note`, `h2`). The kit itself says to strip it at port time — it is not
  part of the product, and its bare `body`/`h2` rules would leak into every page.

  Everything above it is copied byte for byte, comments included: the app's
  stylesheet *is* the design's, and the port is a copy rather than an adaptation.
  Component rules are global, exactly as in the mocks, so a class means the same
  thing here as it does there.

  Short names like `.row`, `.btn`, `.field` and `.dot` collide with the first-cut
  design system still in `assets/css/app.css`, and the kit wins those collisions —
  it is imported last. That restyles the screens that haven't been ported yet, which
  is accepted: nobody is using the app until the rebuild lands, and the alternative
  (scoping the kit to a root class so the two systems coexist) buys compatibility
  nobody needs at the cost of a stylesheet that no longer matches the design.

      mix kit.port           # rewrite assets/css/kit.css
      mix kit.port --check   # exit non-zero if it would change (CI/test guard)
  """
  @shortdoc "Regenerate assets/css/kit.css from the ux/ design kit"

  use Mix.Task

  @source "ux/polyphony-kit.css"
  @target "assets/css/kit.css"

  @header """
  /* ============================================================================
     GENERATED FILE — DO NOT EDIT.

     Ported from ux/polyphony-kit.css by `mix kit.port`, verbatim but for the kit's
     §11 mock chrome. The design kit is the single source of truth: change it in
     ux/, re-run the task, commit both. KitPortTest fails if the two disagree.
     ============================================================================ */

  """

  @impl Mix.Task
  def run(argv) do
    source = Path.join(File.cwd!(), @source)
    target = Path.join(File.cwd!(), @target)
    ported = source |> File.read!() |> port()

    cond do
      "--check" not in argv ->
        File.write!(target, ported)
        Mix.shell().info("Ported #{@source} -> #{@target}")

      File.exists?(target) and File.read!(target) == ported ->
        Mix.shell().info("#{@target} is up to date with #{@source}")

      true ->
        Mix.raise("#{@target} is stale — run `mix kit.port` and commit the result")
    end
  end

  @doc """
  The pure transform: design-kit CSS in, app-kit CSS out.

  Exposed so the drift guard can compare without touching the filesystem.
  """
  @spec port(binary) :: binary
  def port(css), do: @header <> drop_mock_chrome(css)

  @doc "The path of the design kit this file is derived from."
  @spec source_path() :: binary
  def source_path, do: @source

  @doc "The path of the generated stylesheet."
  @spec target_path() :: binary
  def target_path, do: @target

  # § MOCK CHROME to end-of-file, including the banner comment that opens it.
  defp drop_mock_chrome(css) do
    case :binary.match(css, "MOCK CHROME") do
      :nomatch ->
        css

      {at, _} ->
        head = binary_part(css, 0, at)
        # Walk back to the "/*" that opens the section banner.
        cut =
          case last_index(head, "/*") do
            nil -> at
            i -> i
          end

        String.trim_trailing(binary_part(css, 0, cut)) <> "\n"
    end
  end

  defp last_index(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> List.last()
    |> case do
      nil -> nil
      {at, _} -> at
    end
  end
end
