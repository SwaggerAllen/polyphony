# CLAUDE.md

Operational guide for working in this repo. `docs/README.md` indexes the docs and
says where new writing goes; read `docs/architecture.md` for the design, `docs/roadmap.md`
for the near-term schedule, and `docs/decisions.md` for the post-v1 rationale.

## What this is

Polyphony — an event-sourced, multi-agent roleplay engine in Elixir/OTP. One
agent per character plus a world agent ("Director"); the event log is the single
source of truth, and each character sees a **filtered projection** of it.
**Dramatic irony is structural** — a property of the data (`Polyphony.Visibility`),
never a prompt instruction. That guarantee is the thing to protect above all else.

Backend-first, but the LiveView frontend (`PolyphonyWeb`, Phoenix 1.8 / LiveView
1.2) is now built on top, and the app is deployable as an OTP release to
DigitalOcean App Platform. The whole domain still runs and is tested offline. See
`docs/frontend.md` and `docs/deployment.md`.

A **frontend redesign** is speced but not yet built: the `ux/` folder holds the
design pass — static mocks (`polyphony-*.html`), a component kit
(`polyphony-kit.css` + `polyphony-kit.html`), and `ux/README.md` (IA/copy/porting
notes). `polyphony-kit.css` is the **single source of truth** for tokens and every
component class. When that rework lands, port from the kit as directly as possible —
lift its classes and markup rather than re-deriving them — so the shipped UI and the
design don't drift. The backend work the redesign depends on is tracked in
`docs/backend-backlog.md`.

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
   in `Polyphony.Visibility.visible_to?/3` is invisible to characters. A forgotten
   clause makes a character know too *little*, never too much. Omniscient sees all.
2. **No LLM in an aggregate (rule 1).** Aggregates (`Scene`, `Director.Beat`) are
   pure — Commanded replays them. Generation happens only in Oban jobs (or the
   inline runner), which *produce commands*.
3. **Canonical reads (rule 6 / §7).** Every read that feeds fiction to anyone —
   character conditioning, the broadcaster, scene-close — must go through
   `Polyphony.Packets.canonical/1` so re-rolled/superseded packets never reappear.
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
  design system is **deleted**, so **screens that haven't been ported render unstyled**;
  that's deliberate, the app has no users until the rebuild lands. Review components at
  `/storybook`, and give any new one a story — the suite requires it.

## The design inbox (drain it when asked, not on every session)

Design happens in a **normal Claude thread** — faster to iterate with, and it doesn't
block this one. Its instructions are `docs/design-thread.md`. It hands work over in two
pieces, and never writes to the repo itself:

- **Linear** carries the intent — an issue labelled `design-inbox` saying what changes
  and why. This is the instruction.
- **Google Drive** carries the material — a mock HTML file in the folder
  `1y1HudA1L2Ns36Hx_CmO0BDGDp8bBmfuv`, named in the issue as `Drive: <title> (<fileId>)`.
  This is never canonical; `ux/` in the repo is.

To drain it, when the author asks:

1. **Linear** — find open issues labelled `design-inbox`. Read the whole description; the
   argument in it is the part that decides whether the change is right, and the part
   nothing else records. If the Linear connector isn't attached to this session, say so
   and ask for the issue to be pasted rather than guessing at what's queued.
2. **Drive** — for each issue with a `Drive:` line, `download_file_content` on that
   `fileId`, base64-decode it, and **check the byte count against Drive's `fileSize`**
   before doing anything with it. The transport is byte-exact when the design thread sets
   `disableConversionToGoogleType: true`; a size mismatch means it didn't, and the file
   is a Google Doc's idea of the file rather than the file.
3. **Land it in a scratch directory first**, not `ux/`. A mock that arrives straight into
   the design source of truth is a design change nobody looked at. Read it, check its
   classes against `ux/polyphony-kit.css` — a class that isn't there means the mock is
   proposing a **new kit component**, which is a decision, not a port — then commit it to
   `ux/` and run `mix docs.publish` so `/ux/` serves the new one.
4. **Close the loop in Linear**: comment on the issue with what landed and the commit,
   and say plainly if you didn't do part of it and why. An issue that goes quiet is
   indistinguishable from one nobody read.

Two standing rules. A **mock is a proposal, not an instruction** — if it can't be built
as drawn, or it contradicts something in `architecture.md`, say so on the issue instead
of building a worse version of it silently. And the design thread only ever *proposes*
kit changes: `ux/polyphony-kit.css` is edited here, followed by `mix kit.port`, because
`assets/css/kit.css` is generated from it and a test fails on drift.

## Identity & numbering (easy to get wrong)

- `scene_id` is the event-store stream id and stands in for a branch. A **fork** is
  a new scene stream (`Polyphony.Fork`, copy-on-fork).
- `character_id` is the character's **library entry id** — never their display name.
  It is the routing key everywhere: membership, visibility (including a whisper's
  `addressed_to`), `packet_id`, arc `subject_id`, control modes, broadcast topics.
  Names are *display*, resolved at the edges by `Polyphony.Scene.Cast` —
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
