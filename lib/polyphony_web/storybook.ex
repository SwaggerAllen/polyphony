defmodule PolyphonyWeb.Storybook do
  @moduledoc """
  The component catalogue for `PolyphonyWeb.Kit`.

  `ux/polyphony-kit.html` is the design's catalogue — every component and state,
  drawn once. This is its live counterpart: the same components as they actually
  render, reviewable on their own page instead of only in situ on a screen. The
  reason for adopting it is drift (`completed-roadmap.md`, "Frontend rebuild — the
  design-kit foundation"): when a component's states live in one place, a screen
  can't quietly invent a sixth one.

  It is mounted at `/storybook`, gated **per request** on the `:storybook` config
  flag — on in dev, off elsewhere unless `STORYBOOK=true` (see `config/runtime.exs`).
  Nothing in it reads the domain, so it needs no database and no LLM.

  The stories are compiled **into this module** outside dev (`phoenix_storybook`'s
  `:eager` mode), so `storybook/` has to be present when the release is built. It
  silently tolerates a missing content path — `Entries.content_tree/1` returns `[]`
  rather than raising — which means a build that doesn't copy the directory produces a
  catalogue with nothing in it and says nothing about it. The check below turns that
  into a build failure, which is what it is.

  The storybook loads its own asset bundles rather than the app's, so
  `assets/css/storybook.css` re-imports the ported kit; see that file for why it
  deliberately leaves Tailwind's preflight out.
  """
  # Compile-time, deliberately: the stories are compiled in at this moment, and this is
  # the only moment at which their absence is still fixable. Written out rather than
  # bound to an attribute because `use PhoenixStorybook` wants `content_path` as an
  # expression it can evaluate at expansion, and an attribute reaches it as AST.
  unless File.dir?(Path.expand("../../storybook", __DIR__)) do
    raise "storybook content path missing: #{Path.expand("../../storybook", __DIR__)} — " <>
            "a release build must copy `storybook/` (see the Dockerfile), or the " <>
            "catalogue ships empty"
  end

  use PhoenixStorybook,
    otp_app: :polyphony,
    content_path: Path.expand("../../storybook", __DIR__),
    # Remote paths, not filesystem ones — these are what the browser fetches.
    css_path: "/assets/storybook.css",
    js_path: "/assets/storybook.js",
    title: "Polyphony — the kit",
    sandbox_class: "polyphony-storybook"
end
