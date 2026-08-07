defmodule Polyphony do
  @moduledoc """
  The domain. Everything the engine is, with no knowledge of the web layer.

  This module exists to carry a **boundary declaration** — there is no code here and
  there shouldn't be. `Polyphony.*` is the event-sourced core: aggregates, visibility,
  the beat loop, authoring, accounts, costs. `PolyphonyWeb.*` is a Phoenix layer over
  the top and the dependency only ever points that way.

  ## What is enforced

  Both directions are checked. The domain calling `PolyphonyWeb` is a compile error,
  which is the rule worth having and which turned out to already hold — declaring it
  pinned a property rather than fixing one.

  ## Why `exports: :all` stays

  It was meant to be temporary. The rule actually worth enforcing is finer than a
  module: a screen may call `Library.payload/1` (which is `decode(bin)`) and may not
  call `Library.get/1` (which reads). Those live in the same module, and boundary checks
  cross-*module* calls, so **no declaration can separate them**.

  The obvious answer was to move the pure projections onto their own modules until the
  permitted set was expressible. Counting the callers killed it: `Library.payload/1` has
  **thirteen callers in the domain against twelve in the web layer**, `Scene.Cast.render_name/2`
  is three against three, `WorldBible.entries/1` three against three. That refactor would
  rewrite more domain call sites than web ones and leave `payload/1` somewhere other than
  `Library` — the domain made worse so that a tool could check something a test already
  checks more precisely.

  So the per-function rule stays with `Polyphony.Test.Purity`, which computes what can
  reach the repo from the call graph and needs no declaration to maintain, and boundary
  keeps the coarser job it is actually good at: the layers point one way, and the domain
  cannot grow a dependency on the web.

  One thing this does not catch, and it is worth knowing rather than discovering:
  `Polyphony.Application` names `PolyphonyWeb.Endpoint` and `PolyphonyWeb.Telemetry` in
  its supervision tree. Boundary tracks *calls*, and a module named as a value is not
  one — which is the right answer here, since the application module is the composition
  root and is the one place allowed to know about both halves.
  """
  use Boundary, deps: [PolyphonyCore], exports: :all
end
