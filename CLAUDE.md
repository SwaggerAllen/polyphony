# CLAUDE.md

Operational guide for working in this repo. `docs/README.md` indexes the docs and
says where new writing goes; read `docs/architecture.md` for the design and
`docs/decisions.md` for the post-v1 rationale. **The near-term schedule is not a document** —
open work is the Linear project `Polyphony` (team `StrutCo`); see "The worklist" below.

## What this is

Polyphony — an event-sourced, multi-agent roleplay engine in Elixir/OTP. One
agent per character plus a world agent ("Director"); the event log is the single
source of truth, and each character sees a **filtered projection** of it.
**Dramatic irony is structural** — a property of the data (`PolyphonyCore.Visibility`),
never a prompt instruction. That guarantee is the thing to protect above all else.

Backend-first, but the LiveView frontend (`PolyphonyWeb`, Phoenix 1.8 / LiveView
1.2) is now built on top, and the app is deployable as an OTP release to
DigitalOcean App Platform. The whole domain still runs and is tested offline. See
`docs/frontend.md` and `docs/deployment.md`.

The **frontend redesign has landed**: all fifteen screens are ported from the kit and
live in `PolyphonyWeb.Screens.*` as pure function components, each with a story in
`/storybook` and a behaviors doc in `docs/behaviors/`. The `ux/` folder holds the design
pass it was ported from — static mocks (`polyphony-*.html`), the component kit
(`polyphony-kit.css` + `polyphony-kit.html`), and `ux/README.md` (IA/copy/porting notes).
`polyphony-kit.css` remains the **single source of truth** for tokens and every component
class: port from it as directly as possible, lifting its classes and markup rather than
re-deriving them, so the shipped UI and the design don't drift. What is left of the
**Frontend rebuild** milestone is in Linear.

## Commands

```bash
mix deps.get
mix assets.setup             # fetch the esbuild + tailwind binaries (once)
mix test                     # full suite; the alias migrates the test DB first
mix test test/polyphony/foo_test.exs   # one file
mix test --only feature      # real-browser (Wallaby) E2E; excluded by default, needs a browser
                             # run bin/setup-chromedriver first — the sandbox's driver
                             # and its Chromium are different majors
mix format                   # always run before committing
mix compile --warnings-as-errors       # must stay clean
mix run -e "…"               # exercise the loop offline against LLM.Mock
mix assets.build             # rebuild priv/static/assets/{app,storybook}.{js,css} after assets/
mix kit.port                 # regenerate assets/css/kit.css from ux/polyphony-kit.css
mix docs.publish             # copy docs/ + ux/ into priv/static so the app serves them
                             # (run after editing either; CI + a test fail on drift)
mix dialyzer                 # type analysis; first run builds the PLT (~2 min, cached)
mix deps.audit               # dependency advisories (CI: blocking)
mix sobelow --exit low --skip  # Phoenix static analysis (CI: blocking)
mix deps.unlock --check-unused # stale mix.lock entries (CI: blocking)
                             # architectural boundaries are checked by a mix compiler —
                             # `mix compile --warnings-as-errors` is what blocks on them
mix phx.server               # the LiveView frontend at :4000 (watches + rebuilds assets),
                             # the component catalogue at :4000/storybook, and the docs
                             # at :4000/docs — `docs/` and `ux/` served as files, no auth
```

The frontend (`PolyphonyWeb`) is a thin Phoenix LiveView layer; `mix phx.server`
needs the dev DB (`MIX_ENV=dev mix ecto.create && mix ecto.migrate` once). Assets go
through a **real esbuild + tailwind build** (source in `assets/`), but the built
outputs `priv/static/assets/app.{js,css}` are **committed**, so the app compiles and
serves with no build step — CI has an asset-drift guard that rebuilds and fails on
divergence.

**Toolchain: Elixir 1.17 / OTP 27.** In Claude Code on the web the base image is
1.14 / OTP 25; the `SessionStart` hook (`.claude/hooks/session-start.sh`) installs
the modern toolchain into `/opt` (and no-ops once the base is current). Because OTP
27 ships its include headers, the old Floki/leex and cert-task header workarounds
are gone — the suite uses `lazy_html` (LiveView 1.2's DOM backend), not Floki.

**Postgres must be running for the suite.** In this environment it starts down;
bring it up with:

```bash
pg_ctlcluster 16 main start
```

The read models need it (and `CREATE EXTENSION vector` per DB — already set up).
In **dev/test the event store is Commanded's in-memory adapter**, so the domain core
needs no Postgres for the log; only the Ecto read models do. In **prod** the event
store is persistent (`Polyphony.EventStore`, an `eventstore` schema in the same DB) —
the adapter is chosen by env in `config/config.exs`. Don't add event-store
provisioning to the test path.

## Non-negotiable invariants

Breaking any of these silently breaks the core guarantee. Guard them in review.

1. **Default-deny visibility (rule 3).** Any event type without an explicit clause
   in `PolyphonyCore.Visibility.visible_to?/3` is invisible to characters. A forgotten
   clause makes a character know too *little*, never too much. Omniscient sees all.
   It lives in **`PolyphonyCore`**, a sibling boundary declared `deps: []` — nothing in
   there may call the rest of the app at all, so a read inside the visibility rules is a
   compile error rather than a review catch. `PolyphonyCoreTest` holds the same namespace
   to a wider floor per-function: no repo, event store, provider, PubSub, mail, files,
   processes or ETS — and separately to a **replay** floor, since a clock or a die inside
   a projection is not an effect and still makes the answer depend on when you asked.
2. **No LLM in an aggregate (rule 1).** Aggregates (`Scene`, `Director.Beat`) are
   pure — Commanded replays them, so a provider call would re-fire and rebuild the same
   log into a *different story*. Generation happens only in Oban jobs (or the inline
   runner), which *produce commands*. **Both aggregates are in `PolyphonyCore`** (`deps: []`),
   so a read or a provider call inside either is a compile error — `Scene` moved there with
   the data it arbitrates over (`Commands`, `TurnPacket`, `Scene.Cast`). `AggregatePurityTest`
   still walks the call graph from `execute/2` and `apply/2` at three floors — the
   repo/event-store, the provider, and **replay** (clocks, randomness, generated ids, which
   are not effects and break a rebuild anyway) — and a further test fails when a module
   grows both callbacks and nobody adds it to the list.
3. **Canonical reads (rule 6 / §7).** Every read that feeds fiction to anyone —
   character conditioning, the broadcaster, scene-close — must go through
   `PolyphonyCore.Packets.canonical/1` so re-rolled/superseded packets never reappear.
   The stream-read sites (`BeatOps.messages_for`, `Broadcast.Publisher`,
   `SceneClose`) already do; any new one must too.
4. **Membership at the event's beat, not "now".** `member_at?(scene, char, beat)`
   with half-open intervals `[entered, exited)`. `MembershipSet` (pure) and
   `ReadModels.Membership` (Postgres) must answer identically — pinned by a parity
   test.
5. **Knowledge is never self-reported (rule 4).** Membership/visibility are pure
   projections over the log, never fields a character sets.

When adding an event type, decide its `visible_to?` clause deliberately, and if it
carries `packet_id`, make sure the canonical filter and idempotency logic account
for it.

## Conventions

- **Test everything.** Each feature ships with tests; the visibility guarantee gets
  tested hardest. Pure logic is tested as pure functions; end-to-end slices dispatch
  real commands through `Polyphony.App`.
- `mix format` clean and `--warnings-as-errors` clean before every commit.
- **Dialyzer stays at zero.** CI blocks on it. Only `:extra_return` /
  `:missing_return` are enabled — a spec that disagrees with what the function can
  actually return — because on this codebase every one of those was a real defect,
  while `:unmatched_returns` was 66 findings of idiomatic noise. Two consequences
  worth knowing before you fight it: a module referenced as `Mod.t()` must *declare*
  `@type t` (`Ecto.Schema` does not generate one, and an unknown **remote** type
  compiles fine and only fails here), and Dialyzer infers a function's success typing
  from its body alone, ignoring the spec's parameter types — so an integer sum reached
  through `Enum.sum/1` (spec'd `:: number()`) widens to `number()` and needs a guard
  or a `length/1` to stay provable.
- **Spec what crosses a boundary**, not everything. A context's public functions,
  anything returning a tagged tuple or a nilable, and any id-shaped string worth
  naming (`scene_id`, `character_id`, `beat`). Commanded `execute/2` and `apply/2`
  clauses and LiveView callbacks are *not* worth specs — the shapes are the structs.
- Prefer **reuse over new abstraction** — check what the existing generation /
  supersession / fork primitives already give you before adding machinery. Re-rolls,
  edits, and forks all share the supersede-and-recommit primitive for this reason.
- Read moduledocs — they carry the "why" and cite the design-brief sections (§n).
- **Port the frontend from `ux/`, don't re-invent it.** New/redesigned screens take
  their tokens and component classes from `ux/polyphony-kit.css` and their markup
  states from the mocks — the closer the port, the less the implementation drifts from
  the design. Define nothing screen-local that the kit already provides.
  In practice: `assets/css/kit.css` is **generated** from the design file by `mix kit.port`
  — a verbatim copy minus the kit's mock chrome, never hand-edited (a test fails if it
  drifts) — and the kit's markup lives in `PolyphonyWeb.Kit` as function components. A
  ported screen calls those inside a `Kit.frame/1`, which sets the register and theme the
  tokens key on. `app.css` is an ordered manifest (Tailwind → kit) and the kit is last, so
  it outranks a utility it overlaps with — the precedence the mocks have. The first-cut
  design system is **deleted**, so anything not built from the kit renders unstyled. Review
  components at `/storybook`, and give any new one a story — the suite requires it.
- **What a screen *should* do lives in `docs/behaviors/<screen>.md`**, one section per state,
  each named for its storybook variation. Three files answer three different questions and
  it is easy to put a note in the wrong one: `architecture.md` says why the code is shaped
  this way, `ux/` says what it looks like, `docs/behaviors/` says what it does from the seat
  of the person using it. The last is the only one a design thread writes into, and the only
  one with a `rev` — bump it whenever you change a screen's behavior, **including for a fix
  made here with no ticket**, because those are precisely the changes nothing else records.
  `BehaviorsDocTest` pins the state list to the storybook so the prose can't outlive what it
  describes.
- **A screen is a function of its assigns**, held by two guards because one tool can't
  express the whole rule. `PolyphonyWeb.Screens` is a **boundary**, so the modules a screen
  may name are exactly `PolyphonyWeb`'s export list — presentation only, no `Auth`, no
  `Guard`, no `Endpoint` — plus the domain; naming anything else is a compile error. And
  `Polyphony.Test.Purity` walks the call graph for the finer question boundary can't reach:
  `Library.payload/1` is fine and `Library.get/1` is not, and they share a module. Read
  `lib/polyphony.ex` before proposing to fix that with a refactor — the caller counts that
  ruled it out are in there.

## The worklist (Linear, not a document)

**Every open item is a Linear issue** in the **`Polyphony`** project (team `StrutCo`).
That project *is* the scope: an issue outside it isn't part of this loop and isn't yours
to act on. `docs/roadmap.md` and `docs/backend-backlog.md` used to hold this and are
**retired** — a worklist wants a tracker, because prioritising, moving and closing are
things a markdown list can't do. Their shipped half is in `docs/completed-roadmap.md`;
things deliberately ruled out are the **Confirmed non-asks** project document, which is
worth reading before building anything that looks obviously missing.

**Labels describe the work; states describe who has it.** The only labels are
**`frontend`** / **`backend`** — which never change, because a thing doesn't stop being
frontend work — plus `design-inbox` for provenance. Anything you'd have to *remove* when
the work changes hands is a state wearing a label, which is why there is no `deferred`
(that is Backlog) and no `needs-design` (that is Designing). Milestones carry the
sequencing the roadmap used to argue for — **Frontend rebuild** (the critical path; the
app has no users until it lands), then **Authoring quality**, then **World simulation**.

Some issues arrive from elsewhere. Design happens in a **normal Claude thread** — faster
to iterate with, and it doesn't block this one. Its instructions are
`docs/design-thread.md`, it never writes to the repo, and it hands work over in two
pieces:

- **Linear** carries the intent — an issue saying what changes and why, tagged
  `design-inbox`.
- **Google Drive** carries the material — a mock HTML file in the folder
  `1y1HudA1L2Ns36Hx_CmO0BDGDp8bBmfuv`, named in the issue as `Drive: <title> (<fileId>)`.
  This is never canonical; `ux/` in the repo is.

**The queue is a state, not a label.** Every state answers *who has the ball*, and each
answers it differently — which is the test for whether a state earns its place:

| State | Who has it |
|---|---|
| Backlog / Todo | Nobody. |
| Designing | The design thread. Still has open questions — **not yours yet**. |
| **Ready for dev** | **The queue. This is what you drain.** |
| In Progress | You, now. |
| Ready to merge | The author. A PR is open. (Linear's default `In Review`, renamed.) |
| Done / Canceled | Nobody. A rejected proposal is **Canceled**, never Done. |

The `design-inbox` label is provenance — *this came from the design thread* — and is
worth reading for context, but it is never the queue: a label doesn't move, and two
issues with the same label can be in completely different states.

To drain the design inbox, when the author asks — and the same first step is how you pick
up any queued work, design-thread or not:

1. **Linear** — list issues in **Ready for dev** in the **Polyphony** project. Both
   filters matter: the state is the queue, the project is the scope. Read the whole
   description; the argument in it is the part that decides whether the change is right,
   and the part nothing else records. Move an issue to **In Progress** when you start
   it, and to **Ready to merge** when the PR is open — the author merges, and that
   column is the only place an unmerged PR is visible. If the Linear connector isn't
   attached to this session, say so and ask for the issue to be pasted rather than
   guessing at what's queued.
2. **Drive** — for each issue with a `Drive:` line, `download_file_content` on that
   `fileId`, base64-decode it, and **check the byte count against Drive's `fileSize`**
   before doing anything with it. The transport is byte-exact when the design thread sets
   `disableConversionToGoogleType: true`; a size mismatch means it didn't, and the file
   is a Google Doc's idea of the file rather than the file.
3. **Check the base before applying anything.** For every `Base: <screen>.md rev <n>` line
   on the issue, compare it against the file in the repo. **Equal — apply cleanly. Higher
   in the repo — something moved while the design was being drawn**, and it will usually
   be an undesigned fix made right here, since small changes never get an issue. Reconcile
   by hand: keep both, unless the two touch the same behavior, in which case **the repo
   wins and the issue goes back to Designing** with a comment saying what moved. Never
   reconcile a design by guessing — that produces a design nobody agreed to.
4. **Land it in a scratch directory first**, not `ux/`. A mock that arrives straight into
   the design source of truth is a design change nobody looked at. Read it, check its
   classes against `ux/polyphony-kit.css` — a class that isn't there means the mock is
   proposing a **new kit component**, which is a decision, not a port — then commit it to
   `ux/` and run `mix docs.publish` so `/ux/` serves the new one. A kit change arrives as
   a **fragment**, never a whole file: paste it into `ux/polyphony-kit.css`, run
   `mix kit.port`, and if the class already exists, that collision is the conflict signal —
   stop and ask rather than overwriting.
5. **Docs first, then code.** Land the behaviors doc (`docs/behaviors/<screen>.md`, bumping
   its `rev`) before implementing, so what you build against is in the repo rather than in a
   Drive file. That ordering is also what makes the next design session's base meaningful.
   A new `### \`state\`` section obliges a storybook variation of the same name — `BehaviorsDocTest`
   fails while the two sets disagree, which is what stops the docs describing an app nobody
   can look at.
6. **Close the loop in Linear**: open the PR, move the issue to **Ready to merge**, and
   comment with what landed and the commit. Say plainly if you didn't do part of it and
   why. An issue that goes quiet is indistinguishable from one nobody read — and an issue
   moved without a comment is a state change nobody can audit. The author merges; feedback
   in scope comes back as **Ready for dev**, anything new is a **new issue**, and a merged
   issue with nothing outstanding is **Done**.

**Issues are for designed work.** A small fix — a wrong label, a broken state, a rename —
happens right here and never gets an issue. That is the intended behaviour and it is
precisely why behaviors docs carry a `rev`: the undesigned changes are the ones no ticket
warns the design thread about, so the counter is the only thing that says the ground moved.

**Never file an issue unless the author asks for one.** Not bugs, not findings, not work
you noticed on the way past — say it in the conversation and let the author decide. A
tracker is a queue somebody has committed to, so filing into it is a scheduling decision
and it is theirs. **Bugs in particular are not issues**: they are found, fixed, and gone,
and a bug parked in a queue is one that has been rescheduled rather than repaired.

Two standing rules. A **mock is a proposal, not an instruction** — if it can't be built
as drawn, or it contradicts something in `architecture.md`, say so on the issue and put
it back in **Designing** rather than building a worse version of it silently. Rejecting
one outright is **Canceled**, so the Done column stays a record of what shipped. And the
design thread only ever *proposes* kit changes: `ux/polyphony-kit.css` is edited here,
followed by `mix kit.port`, because `assets/css/kit.css` is generated from it and a test
fails on drift.

## Identity & numbering (easy to get wrong)

- `scene_id` is the event-store stream id and stands in for a branch. A **fork** is
  a new scene stream (`Polyphony.Fork`, copy-on-fork).
- `character_id` is the character's **library entry id** — never their display name.
  It is the routing key everywhere: membership, visibility (including a whisper's
  `addressed_to`), `packet_id`, arc `subject_id`, control modes, broadcast topics.
  Names are *display*, resolved at the edges by `PolyphonyCore.Scene.Cast` —
  `render_name/2` on the way out (prompts, the transcript, any label), and
  `resolve_addressees/2` on the way in, immediately before `CommitPacket`. Both have
  an identity fallback, so an unmapped value passes through as itself. **Never put a
  name where a routing key belongs**: under default-deny that fails safe (the whisper
  reaches nobody) but it's still a bug, and it's the class of bug §5.2 existed to end.
- `packet_id = "#{scene}-#{beat}-#{character}"` (base attempt). Re-rolls/edits add
  `-r<n>`: `BeatOps.reroll_packet_id/4`. **Attempt numbering is max-seen + 1**
  (`BeatOps.next_attempt/4`), not a count — a fork copies only the canonical take,
  so counting would re-use a live id.
- `beat_ref = "#{scene}-b#{beat}"` is the Beat aggregate's separate stream id;
  integer `beat` is a grouping label, **not** an ordering key (order is the event
  store's global sequence, and serial within a beat).

## Environment gotchas

- **Elixir 1.17 / OTP 27** (via the SessionStart hook; see Commands above). The two
  legacy 1.14-era pins are gone (`ecto_sql ~> 3.14`, `postgrex ~> 0.22`); the DeepInfra
  adapter still uses Erlang `:httpc` rather than Req, which remains optional cleanup.
  See the README "Toolchain notes".
- **The debug drawer is the mobile console.** `DEBUG_DRAWER=true` turns on a floating
  log viewer (`PolyphonyWeb.DebugDrawerLive`) — the only way to see server logs from a
  phone. It is built from ordinary kit classes over the kit's own `.dock` primitive
  (§11): internal is not an excuse for a second design language, and only the
  *pinning* was missing from the kit. Mail lines are tagged `[mail]` and picked out.
  **It is not admin-gated** (it can't be — its best use is diagnosing sign-in while
  signed out), so nothing that reaches a log may carry a live token or a whole email
  address.
- **LiveDashboard is at `/admin/dashboard`**, gated on `require_admin` in *every*
  env — it lists processes, reads ETS and shows the environment, so a build flag
  wouldn't be enough. `allow_destructive_actions` is off (it can kill processes).
  Metrics live in `PolyphonyWeb.Telemetry.metrics/0` and **only name events something
  already emits** (Oban, Ecto, Phoenix, VM) — nothing in `Polyphony` emits telemetry,
  so there is no domain metric; a permanently empty chart reads as "nothing is
  happening" rather than "nothing is measured". The route has its own CSP with a
  per-request nonce, because the dashboard ships inline `<script>` that
  `script-src 'self'` otherwise refuses — silently. `Telemetry.History` keeps a
  ten-minute ETS backlog so the charts are populated on open rather than only drawing
  what happens while you watch; it borrows LiveDashboard's own (private) datapoint
  extractor so history and live points share a series, and a test fails loudly if an
  upgrade moves it.
- **Mail is viewable locally.** Dev uses Swoosh's `Local` adapter with the real
  `Transport.Email`, so `mix phx.server` then `/dev/mailbox` shows the actual sent
  message — body, and the provider headers — rather than the link the login screen
  prints. No supervision to add: Swoosh's own app supervises the in-memory store
  (`config :swoosh, :local`, default true). The route is gated at request time by
  `:allow_mailbox` — open in dev, HTTP Basic auth from `MAILBOX_PASSWORD` in prod
  (which also switches prod to the Local adapter when no `SMTP_HOST` is set), and 404
  when neither. Basic auth rather than `require_admin` because you need it precisely
  when signed out; it renders every magic link the node has sent, so treat those
  credentials as root.
- **Email is the front door.** Sign-in is magic-link only, so an unconfigured mailer
  means nobody can log in — and it fails *quietly*, because the default
  `Transport.Log` records the notification as `"sent"`. `runtime.exs` arms the real
  SMTP transport only when `SMTP_HOST` **and** `MAIL_FROM` are both set. The login
  screen's on-page link is `:expose_magic_link`, false in prod and pinned by a test:
  it hands a working session to anyone who types a known address.
- **No egress to DeepInfra** in the sandbox. Everything runs on `Polyphony.LLM.Mock`
  (deterministic lorem via `:erlang.phash2`, offline) or `LLM.Stub` (tests). Never
  rely on `Math.random`/`Date` — determinism matters for replay.
- **DeepInfra model ids in `config/config.exs` are placeholders.** Prod uses DeepInfra
  (dev/test don't), and the `:llm` config is env-driven at runtime — set real ids via
  `DEEPINFRA_MODEL` / `DEEPINFRA_MODEL_HEAVY` (+ `DEEPINFRA_API_KEY`). A deploy 404s on
  the first generation until they're real. See `docs/deployment.md`.
- **Projectors are off in tests** (`config :polyphony, start_projectors: false`).
  Read-model tests drive the SQL directly; integration tests derive membership from
  the stored stream via `MembershipSet`. Don't write tests that assume a live
  projector.
