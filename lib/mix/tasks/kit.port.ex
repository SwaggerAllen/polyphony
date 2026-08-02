defmodule Mix.Tasks.Kit.Port do
  @moduledoc """
  Port `ux/polyphony-kit.css` into `assets/css/kit.css`.

  The design kit is the single source of truth for tokens and component classes
  (see CLAUDE.md conventions). Rather than hand-copying it — which is how design
  and implementation drift apart — this task *derives* the app stylesheet from
  the design file by a mechanical transform, and `KitPortTest` fails the build if
  the committed output stops matching. Editing the kit means editing `ux/` and
  re-running this task; there is nothing to hand-maintain on the app side.

  ## The transform

  Two changes, and deliberately no others:

  1. **Drop §11 "mock chrome".** The kit's last section styles the wall labels and
     notes *around* the mock frames (`body`, `:root`, `.wall`, `.note`, `h2`). The
     kit itself says to strip it at port time — it is not part of the product, and
     its bare `body`/`h2` rules would leak into every page.

  2. **Scope component rules to a `.fr` root.** In the mocks each frame is rooted
     at `<div class="fr stage dark">` and the kit is the only stylesheet, so short
     names like `.row`, `.btn`, `.field` are safe. In the app they collide with the
     first-cut design system still in `assets/css/app.css` (`.row`, `.btn`, `.dim`,
     `.field`, `.dot` are all live in unported screens). Prefixing each component
     selector with the frame root confines the kit to kit-rendered subtrees, so
     screens port one at a time with the rest of the app untouched.

     Register and token rules (`.fr`, `.stage.*`, `.page.*`) are already gated by
     the root's own classes and pass through verbatim. Everything else is emitted
     twice — as a descendant (`.fr .btn`) and as the root itself (`.fr.btn`) —
     because a mock frame routinely carries a component class on the root element
     (`class="fr stage dark sheet p-4"`).

  Specificity is the reason the prefix is a plain class rather than `:where(.fr)`:
  at 0-2-0 the kit outranks both the legacy component classes and Tailwind's
  utilities regardless of source order, which is the precedence the mocks have
  (they load the kit after the Tailwind CDN). When the last screen is ported the
  legacy block goes away and the scope can go with it.

  Comments carry the design rationale and are preserved verbatim.

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

     Ported from ux/polyphony-kit.css by `mix kit.port`. The design kit is the
     single source of truth: change it in ux/, re-run the task, commit both.
     KitPortTest fails if this file and the kit disagree.
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
  def port(css) do
    @header <> (css |> drop_mock_chrome() |> scope_rules())
  end

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

  # A flat scanner: this CSS has no @media and no nesting, so a rule is
  # "everything since the last `}` up to `{`", with comments passed through.
  defp scope_rules(css), do: scan(css, "", [])

  defp scan("", pending, out), do: IO.iodata_to_binary(Enum.reverse([pending | out]))

  defp scan("/*" <> rest, pending, out) do
    {comment, rest} = take_to(rest, "*/")
    scan(rest, pending <> "/*" <> comment, out)
  end

  defp scan("{" <> rest, pending, out) do
    {prelude, selector} = split_selector(pending)
    {body, rest} = take_body(rest, "")
    scan(rest, "", [[prelude, scope_selector(selector), " {", body, "}"] | out])
  end

  defp scan(<<ch::utf8, rest::binary>>, pending, out),
    do: scan(rest, pending <> <<ch::utf8>>, out)

  # A declaration block, with comments passed through so a `}` inside one can't
  # close the rule early.
  defp take_body("}" <> rest, acc), do: {acc, rest}

  defp take_body("/*" <> rest, acc) do
    {comment, rest} = take_to(rest, "*/")
    take_body(rest, acc <> "/*" <> comment)
  end

  defp take_body(<<ch::utf8, rest::binary>>, acc), do: take_body(rest, acc <> <<ch::utf8>>)
  defp take_body("", acc), do: {acc, ""}

  defp take_to(bin, terminator) do
    case :binary.match(bin, terminator) do
      :nomatch ->
        {bin, ""}

      {at, len} ->
        {binary_part(bin, 0, at + len), binary_part(bin, at + len, byte_size(bin) - at - len)}
    end
  end

  # Everything up to and including the last comment (plus the blank lines after it)
  # is prelude; the remainder is the selector list.
  defp split_selector(pending) do
    case last_index(pending, "*/") do
      nil ->
        {leading_ws(pending), String.trim(pending)}

      at ->
        head = binary_part(pending, 0, at + 2)
        tail = binary_part(pending, at + 2, byte_size(pending) - at - 2)
        {head <> leading_ws(tail), String.trim(tail)}
    end
  end

  defp leading_ws(s) do
    case Regex.run(~r/\A\s*/, s) do
      [ws] -> ws
      _ -> ""
    end
  end

  defp scope_selector(list) do
    list
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&scope_one/1)
    |> Enum.join(",\n")
  end

  # Register/token rules are already gated by the frame root's own classes.
  @roots ~w(.fr .stage .page)

  defp scope_one(selector) do
    if Enum.any?(@roots, &String.starts_with?(selector, &1)) do
      [selector]
    else
      [".fr " <> selector, ".fr" <> selector]
    end
  end
end
