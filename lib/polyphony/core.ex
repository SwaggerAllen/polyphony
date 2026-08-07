defmodule Polyphony.Core do
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

  ## Why there is no boundary declaration here yet

  `deps: []` was the goal and it is not reachable: the core is the rules *over* the event
  log, so it pattern-matches thirteen `Polyphony.Events` structs and the sheet's
  `Boundary` struct. Those are data definitions, which is the right kind of dependency —
  but naming them means making each its own boundary, and then `Polyphony.Core` is a
  **sub-boundary** of `Polyphony`.

  That is where the tool stops. A parent may use its children's exports; code outside the
  parent may not, and `exports: :all` cannot be combined with the mass-export entries that
  would re-export a sub-boundary. So either `Polyphony` enumerates **83 modules** in its
  export list — churning on every new context function — or the web layer loses the fifty
  or so `Core` references it legitimately makes.

  Neither is obviously right, so the namespace and the computed check landed first. The
  declaration is a decision, not a mechanical follow-up.
  """
end
