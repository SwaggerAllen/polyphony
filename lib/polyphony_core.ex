defmodule PolyphonyCore do
  @moduledoc """
  The functional core: the rules of the fiction, as data in and data out.

  No code here — this module names the layer. Eight modules live under it and none of
  them can reach an effect of any kind: not the repo, not the event store, not a
  provider, not PubSub, not mail, not ETS.

  ## Why these eight

  They were already here. `Visibility` is three public functions with a fan-in of seven;
  `Packets` is six with a fan-in of eleven. They sat in a flat root namespace of
  fifty-seven modules alongside the contexts, the infrastructure and the debug tooling,
  so nothing said they were a layer and nothing stopped one of them growing a read.

  Membership was **measured against a floor wider than "does it reach the repo"** — the
  database and event store, plus PubSub, mail, files, processes, ETS, `persistent_term`
  and the provider. That distinction changed the list. Under a repo-only floor
  `Broadcast`, `Mailer` and `DebugLog` all score clean, and they publish, send mail and
  write ETS respectively. They are not here.

  `Polyphony.CoreTest` re-runs that floor over whatever is in the namespace, discovering
  modules rather than reading a list, so the claim above cannot quietly stop being true —
  and it is a **per-function** check, finer than any declaration could be.

  ## Two that did not make it, and what they cost to find

  `Owner` looks like a value type and is really an adapter: `of/1` and `coerce/1`
  pattern-match `%Accounts.User{}`, and `Accounts.User` calls back into `Accounts`, which
  reaches the repo. Removing those clauses is a **193 call-site** change, so `Owner` stays
  outside — the core holds rules, not the bridge from an account to an owner.

  `Publication.Preflight` did not come with `Publication`. It reads scenes to answer
  "what will a reader be unable to see", which is a query, so it is `Polyphony.Preflight`
  now. Had it stayed in the namespace it would have been the first thing to fail the
  check, and the temptation would have been to loosen the check.

  ## Why it is `PolyphonyCore` and not `Polyphony.Core`

  The name is the price of the declaration. `deps: []` is only true because the event
  vocabulary came with it — the core is the rules *over* the log, so it pattern-matches
  thirteen event structs and cannot be a leaf without them.

  As `Polyphony.Core` that made it a **sub-boundary**, and boundary will not let a parent
  combine `exports: :all` with the mass-export entries that re-export a child. The choice
  was `Polyphony` enumerating 83 exports that churn on every new context function, or the
  web layer losing the fifty-odd core references it legitimately makes. A **sibling** has
  neither problem: `Polyphony` and `PolyphonyWeb` both simply depend on it.

  One thing had to move the other way. `Content.gate_boundary/2` and `constrain_boundary/2`
  were the only functions here that knew the shape of a `CharacterSheet.Boundary`, and a
  struct dependency is still a dependency. They are on `Authoring.BoundaryGate` now, beside
  the `resolve/3` that runs right after them — one production caller, so the ceiling capping
  and the gate releasing now sit together, which reads better than where they were.
  """

  use Boundary, deps: [], exports: :all
end
