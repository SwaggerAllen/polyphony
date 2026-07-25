# CLAUDE.md

Operational guide for working in this repo. Read `docs/architecture.md` for the
design and `docs/roadmap.md` for what's planned.

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

## Commands

```bash
mix deps.get
mix assets.setup             # fetch the esbuild + tailwind binaries (once)
mix test                     # full suite; the alias migrates the test DB first
mix test test/polyphony/foo_test.exs   # one file
mix format                   # always run before committing
mix compile --warnings-as-errors       # must stay clean
mix run -e "…"               # exercise the loop offline against LLM.Mock
mix assets.build             # rebuild priv/static/assets/app.{js,css} after touching assets/
mix phx.server               # the LiveView frontend at :4000 (watches + rebuilds assets)
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
- Prefer **reuse over new abstraction** — check what the existing generation /
  supersession / fork primitives already give you before adding machinery. Re-rolls,
  edits, and forks all share the supersede-and-recommit primitive for this reason.
- Read moduledocs — they carry the "why" and cite the design-brief sections (§n).

## Identity & numbering (easy to get wrong)

- `scene_id` is the event-store stream id and stands in for a branch. A **fork** is
  a new scene stream (`Polyphony.Fork`, copy-on-fork).
- `packet_id = "#{scene}-#{beat}-#{character}"` (base attempt). Re-rolls/edits add
  `-r<n>`: `BeatOps.reroll_packet_id/4`. **Attempt numbering is max-seen + 1**
  (`BeatOps.next_attempt/4`), not a count — a fork copies only the canonical take,
  so counting would re-use a live id.
- `beat_ref = "#{scene}-b#{beat}"` is the Beat aggregate's separate stream id;
  integer `beat` is a grouping label, **not** an ordering key (order is the event
  store's global sequence, and serial within a beat).

## Environment gotchas

- **Elixir 1.17 / OTP 27** (via the SessionStart hook; see Commands above). Two
  legacy pins linger from the 1.14 era — `ecto_sql ~> 3.11.0`, `postgrex ~> 0.17.5` —
  and the DeepInfra adapter still uses Erlang `:httpc` rather than Req. All three are
  now bumpable and tracked as cleanup; see the README "Toolchain notes".
- **No egress to DeepInfra** in the sandbox. Everything runs on `Polyphony.LLM.Mock`
  (deterministic lorem via `:erlang.phash2`, offline) or `LLM.Stub` (tests). Never
  rely on `Math.random`/`Date` — determinism matters for replay.
- **Projectors are off in tests** (`config :polyphony, start_projectors: false`).
  Read-model tests drive the SQL directly; integration tests derive membership from
  the stored stream via `MembershipSet`. Don't write tests that assume a live
  projector.
