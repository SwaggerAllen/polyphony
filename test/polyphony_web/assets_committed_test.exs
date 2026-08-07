defmodule PolyphonyWeb.AssetsCommittedTest do
  @moduledoc """
  The committed bundles are the ones `mix assets.build` produces, not the ones the dev
  server left behind.

  `priv/static/assets/{app,storybook}.{js,css}` are **committed** so the app compiles and
  serves with no build step, and CI rebuilds them and fails on any divergence. That guard
  is correct and it is also the slowest possible way to find out, because it needs the
  esbuild and tailwind binaries and it only speaks after a push.

  There is one way these drift that has nothing to do with editing `assets/`, and it has
  now cost two red builds: **running `mix phx.server`**. The dev watcher is
  `esbuild --sourcemap=inline --watch` (`config/dev.exs`), so starting the server rewrites
  both JS bundles with an inline sourcemap appended — a change nobody made, to a file
  nobody was thinking about, which then rides along in the next `git add -A`. The diff is
  one line at the end of a 300 KB bundle and reads as noise.

  So this fails on the fingerprint rather than on the whole file: an inline sourcemap in a
  committed bundle means it came from the watcher, because the configured build
  (`config :esbuild`, no `--sourcemap`) cannot produce one. It runs offline in
  milliseconds and catches the mistake before the push rather than after it.

  It does **not** replace CI's rebuild-and-compare. A genuinely stale bundle — one whose
  source changed and which nobody rebuilt — has no fingerprint to look for, and only
  rebuilding can find it.
  """
  use ExUnit.Case, async: true

  @bundles ~w(app.js storybook.js)

  test "no committed JS bundle carries an inline sourcemap" do
    for name <- @bundles do
      path = Path.join("priv/static/assets", name)
      body = File.read!(path)

      refute body =~ "sourceMappingURL=data:", """
      #{path} has an inline sourcemap, which `mix assets.build` does not produce.

      It was almost certainly written by the dev watcher — `mix phx.server` runs esbuild
      with `--sourcemap=inline` — and then committed by accident. CI rebuilds these and
      will fail on the difference.

      Run `mix assets.build` and commit the result.
      """
    end
  end

  test "the bundles are there and are not empty, so the check above isn't vacuous" do
    for name <- @bundles ++ ~w(app.css storybook.css) do
      path = Path.join("priv/static/assets", name)

      assert File.exists?(path), "#{path} is missing — the app serves it with no build step"
      assert File.stat!(path).size > 0, "#{path} is empty"
    end
  end
end
