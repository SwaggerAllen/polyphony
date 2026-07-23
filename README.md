# Polyphony

An event-sourced, multi-agent roleplay engine. One agent per character plus a
world agent ("Director"); the event log is the single source of truth. Each
character sees a **filtered projection** of that log — dramatic irony is a
structural property of the data, not a prompt instruction.

> Full design rationale lives in the design brief. This README covers what is
> **implemented so far** and how to run it.

## Status

This is the **foundation** — build-order slices 1 & 2 from the brief (§15), the
part deliberately built and tested *before anything else exists*, with **no LLM
involved**:

| Slice | What | State |
|------|------|-------|
| 1 | Event store + aggregates + **visibility projection** | ✅ implemented + tested |
| 2 | Scene + membership **interval read model** | ✅ implemented + tested |
| 3+ | Real generation, context assembly, Director, client, … | ⬜ not started |

The core guarantee — *a character's projection contains only what they could
structurally witness* — is implemented in `Polyphony.Visibility` and pinned by
the test suite (`test/polyphony/visibility_test.exs`), the thing the brief says
to "test hardest."

## Architecture at a glance

```
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
mix test           # 35 tests, no LLM, no network
```

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
| `integration_test.exs` | End-to-end: real commands → event store → projector → filtered stream |

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

## What's next (build order, §15)

3. Single character, single scene, real DeepInfra generation → `TurnPacket`.
4. Context assembler with stable→volatile prefix-cache layering.
5. Director — mechanical arbitration, then the judgment call; serial cast chain.
6. User ingestion + confirmation, then suggestion mode.
7. Scene-close pipeline — per-character summaries, embeddings, arc extraction.
8. Branching, re-rolls, client reconnection.
9. Character/world authoring with field-level regeneration.
