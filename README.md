# Polyphony

An event-sourced, multi-agent roleplay engine. One agent per character plus a
world agent ("Director"); the event log is the single source of truth. Each
character sees a **filtered projection** of that log — dramatic irony is a
structural property of the data, not a prompt instruction.

> Full design rationale lives in the design brief. This README covers what is
> **implemented so far** and how to run it.

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
| 9 | Branching, re-rolls; character/world authoring | ⬜ not started |

Slice 5: the Director's decision-making is pure/stubbable logic (arbitration,
the judgment-decision schema, beat-loop policy, fairness, the beat-lifecycle
aggregate), and `Director.Runner` drives the actual beat loop — decide → apply
plan → serial cast generation → close beat → repeat under `BeatPolicy`, with
truncation on membership change. The whole loop runs offline against the
lorem-ipsum `LLM.Mock` provider (the dev default), so `mix run` produces a real
scene with no network:

```
(mira thinks: Eiusmod tempor incididunt.)
mira: "Magna aliqua enim ad minim veniam."
(otto thinks: Tempor incididunt ut.)
otto: "Aliqua enim ad minim veniam lorem."
```

There are **two runners**, sharing the same tested Director logic:

- `Director.Runner` — inline/synchronous, for offline demos and tests.
- **Oban-driven** (`Jobs.RunBeat` + self-chaining `Jobs.GeneratePacket`) — the
  production path. `RunBeat` makes the one judgment call, opens the beat, and
  enqueues the first cast member; each `GeneratePacket` generates, commits,
  records itself on the beat, then enqueues the next cast member — so serial
  ordering falls out of enqueue-next-on-completion. The last one closes the beat
  and enqueues the next `RunBeat` per `BeatPolicy`. Each character's frozen
  context is fetched from `Context.Store` (ETS) rather than serialized through
  job args. Verified against the **real async queues** in dev:

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

Still to layer on: the LiveView itself, and, later, the notify-me-later path (a
worker subscribed to the same topics turning `awaiting.user` into APNs/FCM
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
| `Polyphony.Director.Runner` | Inline beat loop: serial cast chain + `BeatPolicy` (§10) |
| `Polyphony.Jobs.RunBeat` / `GeneratePacket` | Oban-driven beat loop (production path); shared `Director.BeatOps` |
| `Polyphony.Context.Store` | ETS cache of materialized contexts for job-side lookup |
| `Polyphony.LLM.Mock` | Lorem-ipsum provider — offline dev default, runs the whole loop |
| `Polyphony.Ingest` / `Ingest.HeuristicSegmenter` | User prose → segments → `TurnPacket`; verbatim gate + OOC (§11) |
| `Polyphony.Suggest` | 2–3 turn variants from the character's filtered view (§11) |
| `Polyphony.Broadcast` / `Broadcast.Publisher` | Per-viewer filtered client stream over PubSub + cursor replay (§13) |
| `Polyphony.SceneClose` + `SceneClose.*` | Scene-close fan-out: N+1 filtered summaries, embeddings, arc extraction (§8, §10) |
| `Polyphony.Jobs.SummarizeScene` / `ExtractArc` | Per-unit retryable scene-close jobs (transient→backoff, schema-invalid→cancel) |
| `Polyphony.Failures` + `ReadModels.Failure` | User-facing terminal-failure log with retry + refusal edit-and-resubmit (§12) |
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

Requires **Elixir 1.14+**, **Erlang/OTP 25+**, and **PostgreSQL 16 with
`pgvector`**.

```bash
# One-time Postgres setup (adjust to your environment):
#   a 'postgres'/'postgres' role, and (per database): CREATE EXTENSION vector;

mix setup          # deps.get + ecto.create + ecto.migrate
mix test           # 56 tests, no LLM, no network
```

To point the live provider at DeepInfra, set `DEEPINFRA_API_KEY` (and optionally
override `config :polyphony, :llm`).

The event store currently uses Commanded's **in-memory adapter** so the domain
core is runnable and testable without provisioning the EventStore Postgres
schema. Switching to the persistent adapter is a config-only change — see the
commented block in `config/config.exs`. Postgres is used only for the read
models (and, later, pgvector embeddings).

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

## Security note (toolchain constraint)

The build environment provides Elixir **1.14**, which caps `postgrex` at
`0.17.5`. That version carries advisory **GHSA-r73h-97w8-m54h** (SQL injection
via channel name in `Postgrex.Notifications.listen/3` / `unlisten/3`). **This app
does not use `Postgrex.Notifications`** — Commanded runs on the in-memory pubsub
and all database access is via parameterized Ecto queries — so the vulnerable
code path is never exercised. The remediation is to move to Elixir 1.15+ (which
unlocks patched `postgrex` ≥ 0.20 and the newer `ecto_sql`/`commanded` lines)
once the toolchain allows it; the version pins in `mix.exs` are marked
accordingly.

The same 1.14 cap is why the DeepInfra adapter uses Erlang's built-in `:httpc`
rather than Req: Req's HTTP/2 stack (`hpax`) requires 1.15+ and carries its own
advisory. The provider behaviour keeps the HTTP client swappable, so moving to
ReqLLM after a toolchain bump is a one-module change.

## What's next (build order, §15)

8. Branching, re-rolls, client reconnection.
9. Character/world authoring with field-level regeneration.
- The LiveView itself (the last frontend piece; backend is otherwise complete).
