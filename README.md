# Polyphony

An event-sourced, multi-agent roleplay engine. One agent per character plus a
world agent ("Director"); the event log is the single source of truth. Each
character sees a **filtered projection** of that log — dramatic irony is a
structural property of the data, not a prompt instruction.

> Full design rationale lives in the design brief. This README covers what is
> **implemented so far** and how to run it. See also
> [`docs/architecture.md`](docs/architecture.md) (how it's built),
> [`docs/roadmap.md`](docs/roadmap.md) (what's next), and
> [`CLAUDE.md`](CLAUDE.md) (working in the repo).

## Status

Build-order slices 1–3 from the brief (§15). Slices 1 & 2 are the LLM-free
foundation; slice 3 adds real character generation behind a provider boundary:

| Slice | What | State |
|------|------|-------|
| 1 | Event store + aggregates + **visibility projection** | ✅ implemented + tested |
| 2 | Scene + membership **interval read model** | ✅ implemented + tested |
| 3 | Provider boundary + **structured generation → CommitPacket** (Oban) | ✅ implemented + tested |
| 4 | **Context assembler** (stable→volatile prefix caching) + authored layer | ✅ implemented + tested |
| 5 | **Director**: arbitration, judgment, beat loop + lifecycle + **runner** | ✅ implemented + tested |
| 6 | **User's agent**: prose ingestion + confirmation, suggestion mode | ✅ implemented + tested |
| 7 | **Scene-close pipeline**: per-character summaries (pgvector) + arc extraction | ✅ implemented + tested |
| 8 | Client broadcaster (§13) | ✅ implemented + tested |
| 9 | **Authoring**: character generation + field-level regeneration | ✅ implemented + tested |
| 10 | **Branching family** (§7, §A4): re-rolls, forks, edits | ✅ implemented + tested |
| 11 | **LiveView frontend** (Phoenix 1.8 / LiveView 1.2, viewer-parameterized Play) | ✅ implemented + tested |
| 12 | **Deployment**: OTP release + Dockerfile + DO App Platform, persistent event store | ✅ wired + verified |

Slice 10: re-rolls (in-beat supersession), forks (copy-on-fork streams), and edits
(corrections with the downstream-validity choice) — one supersede-and-recommit
primitive, three operations. See [`docs/architecture.md`](docs/architecture.md) §9.

Slice 5: the Director's decision-making is pure/stubbable logic (arbitration,
the judgment-decision schema, beat-loop policy, fairness, the beat-lifecycle
aggregate). The beat loop is **Oban-driven** (`Jobs.RunBeat` + self-chaining
`Jobs.GeneratePacket`), with the walk *decision* in `Director.BeatWalk` and the
async *acting* in `Director.BeatDriver`. `RunBeat` makes the one judgment call,
declares the turn order, and opens the beat; the walk generates each **autonomous**
slot (committing, recording on the beat, enqueuing the next — so serial ordering
falls out of enqueue-next-on-completion) and **pauses** for a **user-controlled**
or **assisted** slot (§A1/§A2). The last slot closes the beat and enqueues the next
`RunBeat` per `BeatPolicy`, with truncation on membership change. Each character's
frozen context comes from `Context.Store` (ETS), never job args.

The whole loop runs offline against the lorem-ipsum `LLM.Mock` provider (the dev
default); tests drive it synchronously via `Oban.Testing.with_testing_mode(:inline,
…)`, no network:

```
beat 1 mira: "Enim ad minim veniam lorem ipsum."
beat 1 otto: "Lorem ipsum dolor sit amet consectetur."
beat 2 mira: "Consectetur adipiscing elit sed do eiusmod."
beat 2 otto: "Dolore magna aliqua enim ad minim."
```

## Front end

**Decision: LiveView** (active-session-first), with a `Phoenix.PubSub`
broadcaster as the seam so a native/PWA client or a push-notification worker can
be added later without touching the domain.

The **broadcaster is built** (§13): `Polyphony.Broadcast.Publisher`, a Commanded
event handler, publishes each committed scene event to **per-viewer PubSub
topics**, filtered through the same `visible_to?/2` used for character contexts —
so the transport can never leak more than the projection. A LiveView subscribes
to `scene:<id>:omniscient` (the user) or `scene:<id>:character:<id>` (a second
human); a reconnecting client catches up via `Broadcast.replay/4` (cursor). The
publisher derives membership from the event stream, so it needs no Postgres.

Verified end-to-end in dev — the omniscient user receives a character's thoughts
*and* speech; another character's viewer receives only the speech.

Beat framing (`beat.opened/closed`) and user-facing failures are wired:
`Polyphony.Failures` broadcasts `generation.failed` with a `failure_id`, `kind`,
and `retryable`/`editable` flags — the LiveView shows a **retry** button (and, for
a refusal, an **edit-and-resubmit** field). On reconnect the client loads open
failures via `Failures.list_open/1` (they're read-model rows, not part of the
event cursor).

The **LiveView is built** (`PolyphonyWeb`, Phoenix 1.8 / LiveView 1.2): auth
(magic-link, dev-surfaced), the Owner-scoped Library, campaign setup, and the core
**Play** view — a viewer-parameterized transcript (omniscient or as any character)
subscribed to the broadcaster, with the composer committing packets and three
distinct waiting states. The whisper-visibility guarantee is pinned by a LiveView
test. See [`docs/frontend.md`](docs/frontend.md).

Still to layer on later: a few deferred inspector views, and the notify-me-later
path (a worker subscribed to the same topics turning `awaiting.user` into APNs/FCM
pushes).

The core guarantee — *a character's projection contains only what they could
structurally witness* — is implemented in `Polyphony.Visibility` and pinned by
the test suite (`test/polyphony/visibility_test.exs`), the thing the brief says
to "test hardest."

Slice 3 note: the DeepInfra call is not exercised in this environment (no egress
to the provider), so the real adapter is written but the pipeline
(parse → validate → retry → commit) is tested with a deterministic in-process
stub injected at the provider boundary. Swapping the stub for the live adapter is
config only.

## Architecture at a glance

```
                       Oban job (generation, rule 1)
                         │  Provider.complete → PacketSchema.parse
                         ▼
command ─▶ Polyphony.App (Commanded) ─▶ Scene aggregate ─▶ events ─▶ event store
                                           (validates)                   │
                                                                         ├─▶ SceneMemberships projector ─▶ Postgres read model
                                                                         └─▶ Visibility.project/3 ─▶ per-viewer stream
```

Key modules:

| Module | Responsibility |
|--------|----------------|
| `Polyphony.Events` | The event catalog (§7) — immutable facts in the log |
| `Polyphony.Scene` | Scene aggregate: lifecycle, membership, packet decomposition (§6.4) |
| `Polyphony.Commands` / `Polyphony.Router` | Command structs and dispatch |
| `Polyphony.Visibility` | `visible_to?/3` + `project/3` — **the core guarantee** (§8) |
| `Polyphony.LLM.Provider` / `DeepInfra` / `Stub` | Provider adapter boundary (§2, §3) |
| `Polyphony.Generation` / `Generation.PacketSchema` | Structured output + §12 failure classification |
| `Polyphony.Jobs.GeneratePacket` | Oban job: generation → `CommitPacket` (rules 1–2) |
| `Polyphony.Context` / `Context.SceneContext` | Stable→volatile assembler; frozen prefix is the cache unit (§9) |
| `Polyphony.Authoring.*` | WorldBible, CharacterSheet, ArcEntry, EffectiveSheet (§5–6) |
| `Polyphony.Director.Arbitration` / `Options` / `Proposal` | Stage-1 mechanical arbitration (§10) |
| `Polyphony.Director` / `Director.Decision` | Stage-2 judgment call + merged plan (§10) |
| `Polyphony.Director.BeatPolicy` / `Fairness` | Beat-loop stopping rule; casting fairness (§10) |
| `Polyphony.Director.Beat` | Beat-lifecycle aggregate — the §12 synchronization unit |
| `Polyphony.Director.BeatWalk` / `BeatDriver` | The beat walk: shared decision (next slot + mode) + the Oban-driven acting (§A1/§A2) |
| `Polyphony.Jobs.RunBeat` / `GeneratePacket` | The Oban beat loop; shared plumbing in `Director.BeatOps` |
| `Polyphony.Context.Store` | ETS cache of materialized contexts for job-side lookup |
| `Polyphony.LLM.Mock` | Lorem-ipsum provider — offline dev default, runs the whole loop |
| `Polyphony.Ingest` / `Ingest.HeuristicSegmenter` | User prose → segments → `TurnPacket`; verbatim gate + OOC (§11) |
| `Polyphony.Suggest` | 2–3 turn variants from the character's filtered view (§11) |
| `Polyphony.Broadcast` / `Broadcast.Publisher` | Per-viewer filtered client stream over PubSub + cursor replay (§13) |
| `Polyphony.SceneClose` + `SceneClose.*` | Scene-close fan-out: N+1 filtered summaries, embeddings, arc extraction (§8, §10) |
| `Polyphony.Jobs.SummarizeScene` / `ExtractArc` | Per-unit retryable scene-close jobs (transient→backoff, schema-invalid→cancel) |
| `Polyphony.Failures` + `ReadModels.Failure` | User-facing terminal-failure log with retry + refusal edit-and-resubmit (§12) |
| `Polyphony.Authoring.Studio` + `FieldStore` / `DraftSchema` | Character authoring: generate then field-level regenerate; metadata out of the schema (§15) |
| `Polyphony.ReadModels.SceneSummary` / `ArcEntry` | Character-scoped pgvector summaries; proposed-arc authoring table |
| `Polyphony.Context.PgvectorRetriever` | Fetches a character's own distant summaries at scene open — the memory gradient's live link |
| `Polyphony.MembershipSet` | Pure interval fold — reference membership implementation |
| `Polyphony.ReadModels.Membership` | Postgres interval read model (write path + queries) |
| `Polyphony.Projectors.SceneMemberships` | Commanded projector wiring the two together |
| `Polyphony.TurnPacket` | A character's turn before decomposition (§6.4) |

### Invariants enforced here (foundational rules, §4)

- **Default-deny visibility (rule 3).** Any event type without an explicit
  clause in `visible_to?/3` is invisible to characters. A forgotten clause makes
  a character know *too little*, never too much.
- **Membership evaluated at the event's beat, not "now".** A character sees only
  what they could witness *when it happened*.
- **Knowledge is never self-reported (rule 4).** Membership is a pure projection
  over `CharacterEntered`/`CharacterExited`.
- **One predicate for every viewer (§13).** The omniscient user is
  `viewer: :omniscient` routed through the *same* `visible_to?/3`, never an
  unfiltered firehose — so a second human is just another viewer value.
- **No LLM inside an aggregate (rule 1).** The Scene aggregate is pure; nothing
  here generates.

### The two membership implementations, and why

`MembershipSet` (pure, in-memory) is the reference; `ReadModels.Membership`
(Postgres, half-open interval index scan) is the materialized twin. They **must**
answer `member_at?` identically, or a character's context and the visibility
predicate would disagree — the exact seam where irony would leak. The parity is
pinned by `test/polyphony/read_models/membership_test.exs`, which drives one
event scenario through both and compares an exhaustive `(scene, char, beat)` grid.

## Running it

Requires **Elixir 1.17 / Erlang OTP 27** and **PostgreSQL 16 with `pgvector`**.
(In Claude Code on the web, a `SessionStart` hook installs that toolchain
automatically — see `docs/frontend.md` and the note below.)

```bash
# One-time Postgres setup (adjust to your environment):
#   a 'postgres'/'postgres' role, and (per database): CREATE EXTENSION vector;

mix setup          # deps.get + assets.setup + ecto.create + ecto.migrate
mix test           # full suite, no LLM, no network
mix phx.server     # the LiveView at http://localhost:4000 (dev)
```

`mix setup` fetches deps and the esbuild/tailwind binaries (`assets.setup`) and
sets up the read-model DB. To point the live provider at DeepInfra, set
`DEEPINFRA_API_KEY` (and optionally override `config :polyphony, :llm`).

**Event store.** In dev and test the event store uses Commanded's **in-memory
adapter**, so the domain core runs and the whole suite passes offline with no
event-store schema to provision. In **prod** it uses the persistent EventStore
adapter (`Polyphony.EventStore`), so the event log — the single source of truth —
survives restarts; its tables live in a dedicated `eventstore` schema alongside
the read models in the same managed Postgres. The adapter is chosen by environment
in `config/config.exs`; the aggregates are identical either way. See
[`docs/deployment.md`](docs/deployment.md).

## Test layout

| File | Proves |
|------|--------|
| `visibility_test.exs` | The core guarantee: interior events self-only, scene isolation, whispers, membership-at-beat, default-deny, omniscient parity, order preserved |
| `membership_set_test.exs` | Half-open interval semantics, re-entry gaps, scoping |
| `scene_test.exs` | Aggregate validation + packet decomposition + idempotency (§12) |
| `read_models/membership_test.exs` | Postgres ⇄ `MembershipSet` parity across a grid |
| `integration_test.exs` | End-to-end: real commands → event store → filtered stream |
| `generation/packet_schema_test.exs` | §6.4 validation: move cap, speech-only fields, blanks |
| `generation_test.exs` | §12 classification: refusal, empty, transport, schema-invalid, corrective retry |
| `jobs/generate_packet_test.exs` | Job → `CommitPacket` → projection holds; idempotency; refusal cancel |
| `context_test.exs` | Frozen prefix byte-identical across packets; filtered-view guard; dedup + oldest-first budget; retrieval runs once |
| `authoring/effective_sheet_test.exs` | Canon revision override / discovery union in beat order (§5) |
| `director/arbitration_test.exs` | Stage-1: auto-accept trivial, auto-reject impossible, forward novel |
| `director/decision_test.exs` | Decision validation incl. "no dialogue in pacing notes" (§10) |
| `director/director_test.exs` | Two-stage merge: rejections→world events, forwarded rulings, cast/control |
| `director/beat_policy_test.exs` | Depth cap, yield, membership-change truncation |
| `director/fairness_test.exs` | Per-scene speak counts; least-spoken-first ordering |
| `director/beat_test.exs` / `beat_integration_test.exs` | Beat lifecycle + `BeatClosed` split (§12), via pure funcs and real dispatch |
| `director/runner_test.exs` | Full beat loop w/ Mock: serial cast, truncation, rejection→world event, depth-capped loop |
| `llm/mock_test.exs` | Mock emits schema-valid TurnPacket/Decision; deterministic |
| `jobs/oban_beat_test.exs` | Oban-driven loop (inline mode): serial chain, `BeatClosed`, guarantee holds, depth-capped loop |
| `ingest_test.exs` | Verbatim integrity (rewrite/order rejected), heuristic segmentation, OOC split, self-state carry-forward |
| `suggest_test.exs` | Variant count/distinctness, steer, and the filtered-view guard on suggestions |
| `broadcast_test.exs` | Per-viewer fan-out (interior/whisper/scene/lifecycle), message shape, replay cursor |
| `broadcast/publisher_test.exs` | End-to-end filtered publish over PubSub (omniscient vs character viewer) + beat framing |
| `read_models/scene_summary_test.exs` | pgvector store + character-scoped search (never another viewer's summary) |
| `scene_close/summarizer_test.exs` | N+1 summaries from each viewer's filtered transcript (leak guard) |
| `scene_close/arc_extractor_test.exs` | Proposed-only arc entries, filtered, schema-validated |
| `scene_close_test.exs` | Full fan-out: 3 summaries stored scoped, arc proposals, best-effort degradation |
| `context/pgvector_retriever_test.exs` | Scene-open retrieval reads back a character's own summaries, scoped |
| `scene_close/retries_test.exs` | §12 failure classification (transient/permanent) + per-unit job fan-out |
| `failures_test.exs` / `failures/wiring_test.exs` | Record/broadcast/retry/edit-resubmit; a refusal records an editable failure |
| `authoring/studio_test.exs` | Field-level regen: locked untouched, convergence, metadata-out-of-schema, feedback accrual |

## Toolchain notes

The project targets **Elixir 1.17 / OTP 27**. In Claude Code on the web the base
image ships Elixir 1.14 / OTP 25, so a `SessionStart` hook
(`.claude/hooks/session-start.sh`) installs the modern toolchain into `/opt` and
puts it on `PATH`; it short-circuits (no-op) once the base image itself is current,
and runs asynchronously so it rarely costs startup time.

Two legacy version pins remain in `mix.exs` from the old 1.14 days:
`ecto_sql ~> 3.11.0` and `postgrex ~> 0.17.5`. The pinned `postgrex 0.17.5` carries
advisory **GHSA-r73h-97w8-m54h** (SQL injection via channel name in
`Postgrex.Notifications.listen/3` / `unlisten/3`). **This app never calls
`Postgrex.Notifications`** — the domain event notifications go through the
`eventstore` library's own listener and all app queries are parameterized Ecto — so
the vulnerable path isn't exercised. Bumping these pins to patched lines is now
unblocked on the modern toolchain and is a tracked cleanup.

Relatedly, the DeepInfra adapter uses Erlang's built-in `:httpc` rather than Req —
a zero-dependency choice from the 1.14 era. The provider behaviour keeps the HTTP
client swappable, so moving to ReqLLM on the modern toolchain is a one-module
change.

## Deployment

Polyphony ships as a self-contained OTP release. The repo `Dockerfile` builds it
(assets digested via esbuild/tailwind), and `.do/app.yaml` describes a DigitalOcean
App Platform app: a `PRE_DEPLOY` job runs migrations + event-store setup
(`bin/migrate`), then the web service boots (`bin/server`). One managed Postgres 16
cluster backs both the read models (`public` schema) and the persistent event store
(`eventstore` schema). Set `SECRET_KEY_BASE`, `DEEPINFRA_API_KEY`, and `PHX_HOST`;
`DATABASE_URL` is injected by the managed database. Full walkthrough in
[`docs/deployment.md`](docs/deployment.md).

## What's next

The frontend and deployment path are now in. Remaining work is tracked in
[`docs/roadmap.md`](docs/roadmap.md): the post-v1 tiers (deferred inspector views,
the notify-me-later push worker, richer authoring), plus the standing cleanups
(bump the legacy `postgrex`/`ecto_sql` pins now that the toolchain allows it,
optional move to ReqLLM).
