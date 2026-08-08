defmodule Polyphony.OneReadGateTest do
  @moduledoc """
  Nothing outside `Polyphony.Permissions` decides who may read an entry by looking at
  its visibility.

  This is a source scan and it exists because the thing it guards is invisible in every
  other way. There were **five** copies of the sentence *public or unlisted means anyone
  may read it*, in five modules, and four of them were wrong — `unlisted` means reachable
  by the link and not otherwise, and only the copy that nothing called ever checked the
  token. Each one compiled, each one was tested, each one read as obviously correct in
  the file it was in. What was wrong was the count.

  A duplicated authorization rule doesn't fail like duplicated logic. It fails by being
  enforced in some places and not others, and the places it isn't are the ones nobody
  thought to look at — which is exactly what a test can check and a reader can't.

  What it looks for is a comparison against the two **grant** values. `"private"` is the
  absence of a grant and anyone may test for it (`Reading.pulled?/1` asks whether the
  author withdrew a story, which is a different question and stays where it is). Setting
  a visibility is a write, not a decision, so `visibility: "public"` is not a match.

  If this fails, the fix is almost never to add the file to `@gates`. It is to ask
  `Permissions.can_view?/3` — and if it can't answer your question, that means you have a
  question worth naming, like `list_public/2` (what belongs in a catalogue) or
  `Reading.readable?/2` (may this reader carry on). Both of those are real and neither is
  a second gate. A fifth one won't be either, until it is.
  """
  use ExUnit.Case, async: true

  # The gate itself, the catalogue queries (a listing rule is not a reading rule — an
  # unlisted entry is readable by link and must never be browsable), and the context that
  # unpublishes an entry on delete.
  @gates ~w(
    lib/polyphony/permissions.ex
    lib/polyphony/read_models/library_entry.ex
    lib/polyphony/library.ex
  )

  @grant ~r/"public"|"unlisted"|~w\(\s*(public|unlisted)/
  @compares ~r/==|\sin\s/

  test "no module outside the gate decides readability from a visibility value" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          path not in @gates,
          {line, n} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
          code = String.trim(line),
          not String.starts_with?(code, "#"),
          Regex.match?(@grant, code),
          Regex.match?(@compares, code),
          String.contains?(code, "visibility") or Regex.match?(~r/~w\(\s*public/, code),
          do: "#{path}:#{n}  #{code}"

    assert offenders == [], """
    A visibility value is being compared outside `Polyphony.Permissions`:

    #{Enum.join(offenders, "\n")}

    That is how `unlisted` came to mean `public` in four places at once. Ask
    `Permissions.can_view?(entry, actor, token: t)` instead. If the question you actually
    have is "what belongs in a catalogue" or "may this reader carry on", say so in those
    words and put it beside the rule it belongs to — those are different questions, and
    the moduledoc here explains which.
    """
  end

  test "the scan can see the code it is scanning" do
    # A guard whose pattern silently stops matching reads exactly like a clean codebase.
    # Both halves are checked: that the files are found, and that the pattern still fires
    # on the shape it was written for — the literal line this test was born from.
    assert length(Path.wildcard("lib/**/*.ex")) > 100

    line = ~s|Library.snapshot?(entry) and entry.visibility in ~w(public unlisted)|
    assert Regex.match?(@grant, line)
    assert Regex.match?(@compares, line)
  end
end
