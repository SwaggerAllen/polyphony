defmodule PolyphonyWeb.Storybook do
  @moduledoc """
  The component catalogue for `PolyphonyWeb.Kit`.

  `ux/polyphony-kit.html` is the design's catalogue — every component and state,
  drawn once. This is its live counterpart: the same components as they actually
  render, reviewable on their own page instead of only in situ on a screen. The
  roadmap's reason for adopting it is drift (`roadmap.md`, "Frontend redesign &
  design-kit fidelity"): when a component's states live in one place, a screen
  can't quietly invent a sixth one.

  It is mounted at `/storybook`, gated by the `:storybook` config flag — on in
  dev, off elsewhere unless `STORYBOOK=true` (see `config/runtime.exs`). Nothing
  in it reads the domain, so it needs no database and no LLM.

  The storybook loads its own asset bundles rather than the app's, so
  `assets/css/storybook.css` re-imports the ported kit; see that file for why it
  deliberately leaves Tailwind's preflight out.
  """
  use PhoenixStorybook,
    otp_app: :polyphony,
    content_path: Path.expand("../../storybook", __DIR__),
    # Remote paths, not filesystem ones — these are what the browser fetches.
    css_path: "/assets/storybook.css",
    js_path: "/assets/storybook.js",
    title: "Polyphony — the kit",
    sandbox_class: "polyphony-storybook"
end
