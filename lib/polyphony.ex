defmodule Polyphony do
  @moduledoc """
  The domain. Everything the engine is, with no knowledge of the web layer.

  This module exists to carry a **boundary declaration** — there is no code here and
  there shouldn't be. `Polyphony.*` is the event-sourced core: aggregates, visibility,
  the beat loop, authoring, accounts, costs. `PolyphonyWeb.*` is a Phoenix layer over
  the top and the dependency only ever points that way.

  ## What is enforced, and what isn't yet

  Both directions are checked. The domain calling `PolyphonyWeb` is a compile error,
  which is the rule worth having and which turned out to already hold — declaring it
  surfaced no violations, so this pins a property rather than fixing one.

  `exports: :all` is the loose part, and it is temporary. The rule actually worth
  enforcing is finer than a module: a screen may call
  `Library.payload/1` (which is `decode(bin)`) and may not call `Library.get/1` (which
  reads). Those live in the same module, so **no boundary declaration can separate
  them** — boundary checks cross-*module* calls. Saying it properly needs the pure
  projections moved off the context modules they currently sit on, which is a domain
  refactor and a separate piece of work.

  Until then that rule is enforced by `Polyphony.Test.Purity`, which computes what can
  reach the repo from the call graph. Boundary's job here is the coarser one it is
  actually good at: keeping the layers pointed the right way, and stopping the domain
  from growing a dependency on the web.
  """
  use Boundary, exports: :all
end
