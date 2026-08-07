defmodule PolyphonyWeb.DocsServedTest do
  @moduledoc """
  The docs, reachable over HTTP by somebody with no account and no repo.

  They existed only in the repository, which is private — so raw GitHub URLs need
  credentials — and at the repo *root*, which is not in an OTP release: a release ships
  `priv/` and compiled beams and nothing else. There was no URL that reached them,
  anywhere.

  So `mix docs.publish` copies both trees under `priv/static` and they are served as
  files. Three things have to hold, and all three are easy to break silently:

    * the copy is **current** — a doc edited without republishing ships the old one;
    * every published file is **committed**, which is not the same thing: comparing two
      working directories passes on a machine where both exist, and says nothing about
      what a checkout gets;
    * the files are actually **served**, which needs them on `static_paths/0`;
    * `/docs` **lists** them, since `Plug.Static` has no directory listing and a file
      you can only reach by guessing its name is a file nobody reads.
  """
  use PolyphonyWeb.ConnCase, async: true

  alias Mix.Tasks.Docs.Publish

  describe "the published copy" do
    test "is exactly what is in docs/ and ux/" do
      for {source, target} <- Publish.trees() do
        want = Publish.collect(source)
        have = Publish.collect(target)

        assert Map.keys(want) == Map.keys(have),
               "#{target} is stale — run `mix docs.publish` and commit the result"

        assert want == have,
               "#{target} is stale — run `mix docs.publish` and commit the result"
      end
    end

    # The drift check above compares one directory against another, so it is blind to a
    # file that exists on every working tree and in no commit. That is not hypothetical:
    # `.gitignore` carried `/priv/static/**/*-[0-9a-f]*.*` to exclude digested assets,
    # which also matched `polyphony-admin.html`, `design-brief.md` and seven others.
    # Nine published files were untracked for as long as that rule existed — the
    # deployment 404'd on them, CI failed the drift check, and every local run was green,
    # because locally the files are right there.
    test "is committed, not merely present on this machine" do
      for {_source, target} <- Publish.trees() do
        {tracked, 0} = System.cmd("git", ["ls-files", target])
        tracked = tracked |> String.split("\n", trim: true) |> MapSet.new()

        for {path, _} <- Publish.collect(target) do
          file = Path.join(target, path)

          assert MapSet.member?(tracked, file),
                 "#{file} is published but not tracked by git — a checkout would not have " <>
                   "it. Check `git check-ignore -v #{file}`."
        end
      end
    end

    # Being committed and being *in the image* are different claims, and the gap between
    # them cost a second round of exactly the same bug. `.gitignore` and `.dockerignore`
    # both carried `priv/static/**/*-[0-9a-f]*.*`; fixing the first left the deployment
    # 404ing on the same nine files, with git, CI and every local run green — because
    # `COPY priv priv` cannot bring in what the build context never had.
    #
    # So this reads `.dockerignore` rather than restating what it ought to say. A test
    # that asserts "the rule is scoped to assets/" is a second copy of the intent and
    # would drift the same way the first one did.
    test "survives .dockerignore, so the image has it too" do
      patterns = docker_ignore_patterns()

      for {_source, target} <- Publish.trees(), {path, _} <- Publish.collect(target) do
        file = Path.join(target, path)

        refute Enum.find(patterns, fn {regex, source} -> excluded?(regex, file) && source end),
               """
               #{file} is published, committed, and excluded from the Docker build context.

               `COPY priv priv` copies what the context contains, so this file is absent
               from the release and its URL 404s — while git, CI and `mix phx.server` all
               look fine. Scope the offending `.dockerignore` line to `priv/static/assets/`.
               """
      end
    end

    test "carries the files worth naming" do
      docs = Publish.collect("priv/static/docs")
      ux = Publish.collect("priv/static/ux")

      assert Map.has_key?(docs, "architecture.md")
      assert Map.has_key?(docs, "completed-roadmap.md")
      assert Map.has_key?(ux, "polyphony-kit.css")
      # The brief every `§n` in the codebase cites. It lives in an archive subdirectory,
      # so it is also the check that the copy is a tree walk rather than a glob of one
      # level.
      assert Map.has_key?(ux, "archive/design-brief.md")
    end
  end

  describe "over HTTP" do
    test "a doc is served, as text a reader (or a fetcher) gets whole", %{conn: conn} do
      conn = get(conn, "/docs/architecture.md")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/markdown"
      assert conn.resp_body =~ "Polyphony"
    end

    test "so is a design mock and the kit itself", %{conn: conn} do
      assert get(conn, "/ux/polyphony-kit.html").status == 200

      css = get(conn, "/ux/polyphony-kit.css")
      assert css.status == 200
      assert css.resp_body =~ ".hamb"
    end

    test "with no account — that is the whole point", %{conn: conn} do
      # Signed out, no invite, nothing. If this ever needs a session, the docs have
      # stopped being something you can hand to somebody.
      assert get(conn, "/docs/README.md").status == 200
    end

    test "the index names every file it serves, so nothing has to be guessed",
         %{conn: conn} do
      {:ok, _view, body} = live(conn, "/docs")

      for {root, _} <- Publish.trees(),
          {path, _} <- Publish.collect("priv/static/#{root}") do
        assert body =~ ~s(href="/#{root}/#{path}"),
               "#{root}/#{path} is served but not listed at /docs"
      end
    end

    test "and /ux is the same page, because one URL to hand over is the point",
         %{conn: conn} do
      {:ok, _view, ux} = live(conn, "/ux")
      assert ux =~ "/docs/architecture.md"
      assert ux =~ "/ux/polyphony-kit.css"
    end

    test "something that isn't there is a 404, not a directory", %{conn: conn} do
      # A plain 404 from the router, not a listing and not a traversal — `Plug.Static`
      # doesn't match, so it falls through to the router, which has no such route.
      assert get(conn, "/docs/nope.md").status == 404
      # And a traversal is refused by `Plug.Static` itself, before anything reads a
      # path — 400, not a file from outside the two published trees.
      assert_error_sent(400, fn -> get(conn, "/ux/../config/runtime.exs") end)
    end
  end

  # ── Reading .dockerignore ────────────────────────────────────────────────────
  #
  # Enough of Docker's pattern language for the patterns actually in the file: `**`
  # spans path segments, `*` and `?` do not, `[…]` is a character class. Anything it
  # does not understand raises rather than quietly matching nothing — a matcher that
  # silently passes is the failure mode this whole test exists to close.

  defp docker_ignore_patterns do
    ".dockerignore"
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      if String.starts_with?(line, "!") do
        raise """
        .dockerignore line #{inspect(line)} is a negation, and this matcher does not
        implement one. Teach it before relying on this test again — an unread pattern
        makes every assertion here pass.
        """
      end

      {compile(String.trim_trailing(line, "/")), line}
    end)
  end

  defp compile(pattern), do: Regex.compile!("^" <> translate(pattern, "") <> "$")

  defp translate("", acc), do: acc
  defp translate("**" <> rest, acc), do: translate(rest, acc <> ".*")
  defp translate("*" <> rest, acc), do: translate(rest, acc <> "[^/]*")
  defp translate("?" <> rest, acc), do: translate(rest, acc <> "[^/]")

  defp translate("[" <> rest, acc) do
    [class, rest] = String.split(rest, "]", parts: 2)
    translate(rest, acc <> "[" <> class <> "]")
  end

  defp translate(<<c::utf8, rest::binary>>, acc),
    do: translate(rest, acc <> Regex.escape(<<c::utf8>>))

  # A pattern naming a directory excludes everything beneath it, so every ancestor
  # prefix is tested as well as the path itself.
  defp excluded?(regex, path) do
    segments = Path.split(path)

    1..length(segments)
    |> Enum.map(&(segments |> Enum.take(&1) |> Path.join()))
    |> Enum.any?(&Regex.match?(regex, &1))
  end
end
