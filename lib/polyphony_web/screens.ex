defmodule PolyphonyWeb.Screens do
  @moduledoc """
  Every screen, as markup. No code here — this module carries a **boundary declaration**.

  A screen is a function of its assigns and nothing else. That is what makes it
  renderable from fixtures in `/storybook`, and it is what makes `STORYBOOK=true` safe in
  production: a story that could load a campaign would quietly turn that flag into an
  authorization hole.

  ## What this declaration can say, and what it can't

  `deps` is the list of modules a screen may name at all, and it is short on purpose —
  the four helpers below plus the domain. It is what stops a screen from reaching
  `Endpoint` to broadcast, `Auth` to read a session, or `Guard` to make an authorization
  decision. Those are all module-level facts, so boundary can hold them.

  What it **cannot** say is the rule that matters most: a screen may call
  `Library.payload/1` (which is `decode(bin)`) and may not call `Library.get/1` (which
  reads). Those are the same module, and boundary checks cross-*module* calls.

  Splitting them was the obvious answer and the measurement killed it: `Library.payload/1`
  has thirteen callers in the domain against twelve in the web layer, `Cast.render_name/2`
  is three against three, `WorldBible.entries/1` three against three. Moving them onto
  view-shaped modules would rewrite more domain call sites than web ones to satisfy a
  declaration — the domain made worse so a tool can check something a test already checks
  better.

  So the per-function rule stays with `Polyphony.Test.Purity`, which computes what can
  reach the repo from the call graph rather than declaring it, and boundary takes the
  coarser half it is actually good at.
  """
  use Boundary, deps: [Polyphony, PolyphonyWeb], exports: :all
end
