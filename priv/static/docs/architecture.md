# Polyphony — Architecture

How the system is built and why. Companion to the design brief (cited as §n) and
the frontend spec. For day-to-day commands and invariants see `../CLAUDE.md`; for
what's planned see the Linear project `Polyphony`.

---

## 1. The core idea

One agent per character, plus a world agent (the **Director**). The **event log is
the single source of truth**. Each character sees only a **filtered projection** of
that log — the events they could structurally have witnessed. Dramatic irony (a
character furious inside but composed outside; a secret one party holds) is
therefore a property of *the data and its projection*, not a prompt instruction and
not something a model can accidentally reveal.

The load-bearing module is `PolyphonyCore.Visibility`, and **`PolyphonyCore` is a boundary
declared `deps: []`** — a sibling of `Polyphony` rather than a namespace inside it, so
nothing in it may call the rest of the application. The event vocabulary
(`PolyphonyCore.Events`) lives there too, because the core is the rules *over* the log and
cannot be a leaf without the shapes of the facts it reasons about. `PolyphonyCoreTest`
holds the namespace to a wider floor than the compiler can see — no repo, event store,
provider, PubSub, mail, files, processes or ETS — walking the call graph per function.

The rest: `visible_to?/3` decides whether
one event reaches one viewer, and `project/3` filters a stream. The **same
predicate** drives character conditioning contexts *and* the client broadcaster, so
the transport can never leak more than the projection.

## 2. Foundational rules (§4)

1. **No LLM inside an aggregate.** Aggregates are pure and replayed by Commanded;
   generation lives in Oban jobs that *produce commands*.
2. **Jobs produce commands.** Generation → `CommitPacket` (etc.); the aggregate
   validates.
3. **Default-deny visibility.** An event with no `visible_to?` clause is invisible
   to characters.
4. **Knowledge is never self-reported.** Membership/visibility are projections over
   the log.
5. **Serial generation within a beat.** Each cast member conditions on everything
   committed before them.
6. **Events are immutable.** Corrections are new events. A **re-roll** supersedes in
   place (append-only `PacketSuperseded`); a **fork** starts a new stream.

## 3. Event sourcing with Commanded

- `Polyphony.App` is the Commanded application (write side). `Polyphony.Router`
  routes commands to aggregates by identity.
- **Two aggregate/stream families:**
  - **Scene** (`identify(Scene, by: :scene_id)`) — the fiction: lifecycle,
    membership, committed packets, supersession, forks.
  - **Director.Beat** (`identify(Director.Beat, by: :beat_ref)`) — the §12
    synchronization unit: an ordered cast opens, each member reports terminal
    (committed/failed), the beat closes with `BeatClosed{completed, failed}`.
- The **event store adapter is chosen by environment** (`config/config.exs`): dev
  and test use Commanded's **in-memory adapter** (so the domain runs offline and the
  suite needs no event-store schema); **prod** uses the persistent EventStore adapter
  (`Polyphony.EventStore`), which stores events as JSONB in a dedicated `eventstore`
  schema in the same managed Postgres that backs the read models (`public`). The
  aggregates are identical either way. Postgres otherwise backs only the Ecto **read
  models**.
- `PolyphonyCore.Events` is the catalog; every event derives `Jason.Encoder`.

### Event catalog shape

- **Character moves** (decomposed from a `TurnPacket`, sharing `beat` + `packet_id`,
  §6.4): `ThoughtOccurred`, `SpeechUttered`, `ActionTaken`, `PrivateStateReported`,
  `DemeanorReported`. The split of `PrivateStateReported` (felt/intended, self-only)
  from `DemeanorReported` (observable, members-at-beat) *is* the irony at the state
  layer. The three move events carry an `edited` flag (§A4).
- **World/lifecycle:** `WorldEventOccurred`, `SceneOpened`, `SceneClosed`,
  `CharacterEntered`, `CharacterExited`.
- **Beat framing** (on the beat stream): `BeatOpened`, `BeatClosed`,
  `PacketRecorded`, `PacketFailed`.
- **Branching family:** `PacketSuperseded` (re-roll/edit eviction),
  `SceneForked` (fork lineage).
- **Scene-close/authoring:** `ArcEntryProposed`, `ArcEntryAccepted`,
  `GenerationFailed`.

## 4. The Scene aggregate

`Polyphony.Scene` owns lifecycle and membership (the facts that change what everyone
can witness), and decomposes a committed `TurnPacket` into typed move events (§6.4).
State it folds: `members`, `committed_packets` (idempotency), `superseded_packets`
(canonical filter), `forked_from`.

- **Idempotency (§12):** a `CommitPacket` whose `packet_id` is already committed is a
  no-op — a job that crashed after the API call but before recording completion
  re-runs and commits exactly once.
- **Supersession (§7):** `SupersedePacket` appends a `PacketSuperseded` marker
  (never mutates); guarded to committed, non-superseded packets on an open scene.
- **Fork (§7):** `ForkScene` emits `SceneForked` followed by a rewritten copy of the
  parent's canonical prefix — only valid on a fresh (`:pending`) stream.

## 5. Visibility & the canonical filter

`PolyphonyCore.Visibility.visible_to?/3`:

- interior (`ThoughtOccurred`, `PrivateStateReported`) → the owning character only;
- private speech (whispers) → speaker + `addressed_to` only;
- observable (`SpeechUttered` normal, `ActionTaken`, `DemeanorReported`,
  `WorldEventOccurred`, membership) → members at the event's beat;
- everything else → default-deny to characters; omniscient sees all.

`PolyphonyCore.Packets.canonical/1` sits *before* visibility on every fiction-bearing
read: it drops packets named by `PacketSuperseded` markers (and the markers
themselves), so a re-rolled or edited-away turn disappears from every projection at
once — even omniscient. Applied at the four stream-read sites (`Director.BeatOps`,
`Director.Runner`, `Broadcast.Publisher`, `SceneClose`) and in `Broadcast.replay`.

## 6. Membership read model

Two implementations that must agree:

- `PolyphonyCore.MembershipSet` — pure interval fold from the event stream (reference).
- `Polyphony.ReadModels.Membership` + `Projectors.SceneMemberships` — Postgres
  half-open `[entered, exited)` interval index (materialized twin).

Parity across an exhaustive `(scene, char, beat)` grid is pinned by a test — this is
the exact seam where irony would leak if the two disagreed.

## 7. Generation path

```
Oban job (rule 1)  ──▶  Provider.complete  ──▶  Generation.generate
   (GeneratePacket)         (adapter §2)         parse → validate → classify
        │                                              │
        └───────────── dispatch CommitPacket ──────────┘  → Scene aggregate → events
```

- **Provider boundary** (`Polyphony.LLM.Provider` behaviour): `DeepInfra` (real,
  `:httpc`), `Mock` (offline lorem, dev default), `Stub` (tests). A `:response` hint
  selects the schema (`:turn_packet`, `:decision`, `:summary`, `:arc`, `:sheet`,
  `:field`).
- **Structured output** (`Generation` + `Generation.PacketSchema`): parse JSON,
  validate against the §6.4 changeset (move cap, speech-only fields), and **classify
  failures** for the §12 table — refusal (editable), transport (retryable),
  schema-invalid (cancel).
- **Context assembler** (`Polyphony.Context` + `Context.SceneContext`): a
  **stable → volatile** prefix. The stable half (world rules, sheet, resident facts,
  retrieved distant summaries) is frozen at scene open — that frozen prefix is the
  cache unit (§9). Live scene history is appended below it, canonical-filtered.
- `Context.Store` (ETS) holds materialized contexts for job-side lookup, so the
  frozen prefix isn't re-serialized through Oban args.
- `Context.PgvectorRetriever` fetches a character's own distant summaries at scene
  open — the memory gradient's live link.

## 8. The Director & the beat loop (§10)

Two-stage arbitration, then a serial cast:

1. `Director.Arbitration` (Stage 1, mechanical): auto-accept trivial proposals,
   auto-reject impossible ones, forward novel ones; builds option sets.
2. `Director` + `Director.Decision` (Stage 2, one judgment call): casts the beat,
   sets pacing, rules on forwarded proposals, chooses control (`continue` /
   `yield_to_user`). Rejections become `WorldEventOccurred` ("she reaches for the
   door; it's locked").
3. `Director.BeatPolicy` / `Fairness`: depth cap, truncation on membership change,
   least-spoken-first casting.

**One beat loop, Oban-driven.** `Jobs.RunBeat` + self-chaining `Jobs.GeneratePacket`
do the work; the *decision* (next actionable slot + its control mode) is a pure
function in `Director.BeatWalk`, and the *acting* is `Director.BeatDriver`. `RunBeat`
makes the judgment call, declares the turn order (§A1), and opens the beat; the walk
generates each **autonomous** slot (commit, record, enqueue next — serial ordering
falls out of enqueue-on-completion) and **pauses** for a **user-controlled** or
**assisted** slot, resuming via `BeatDriver.submit_user_turn`/`pass_turn`/
`accept_draft`/`discard_draft`. The last slot closes the beat and enqueues the next
`RunBeat`. Progress is re-derived from the log each step, so a pause needs no stored
cursor. Shared plumbing lives in `Director.BeatOps`.

Tests drive the loop synchronously with `Oban.Testing.with_testing_mode(:inline, …)`
against the Mock provider — the same code path production runs, just inline.

## 9. The branching family — one primitive, three operations

All three are the same **supersede-and-recommit** primitive; they differ only in
what the replacement is and whether they cross to a new stream.

| Operation | Module | Replacement | Stream |
|---|---|---|---|
| **Re-roll** | `Polyphony.Reroll` | LLM-regenerated | same (in-beat) |
| **Edit** | `Polyphony.Edit` | user-authored corrected packet | same (`:valid`) or fork (`:invalid`) |
| **Fork** | `Polyphony.Fork` | — (copies the prefix) | new |

- **Re-roll (§7, §12):** bounded to the **latest beat**. Re-rolling `C_k` supersedes
  `C_k` and its in-beat tail (everything that conditioned on it), then regenerates
  the tail serially by reusing `Jobs.GeneratePacket` wholesale (same commit path, same
  refusal→heavy-model retry). Touching an earlier beat is a fork, not a re-roll
  (`:not_latest_beat`).
- **Edit (§A4):** a user-authored re-commit with `edited: true`. `:valid` supersedes
  just that packet in place (any beat), timeline intact. `:invalid` forks through the
  edit beat (preserving the original), then supersedes the edited packet + its in-beat
  tail on the branch — the user's downstream-validity choice, because only they know
  whether the change invalidated later turns.
- **Fork (§7):** copy-on-fork. `Fork.fork/3` copies the parent's *canonical* prefix
  through the fork beat, re-points `scene_id`/`packet_id` onto a fresh stream, and
  emits `SceneForked` + the prefix. The fork is then an ordinary open scene — every
  projection handles it unchanged, and it's fully isolated (editing/re-rolling either
  side can't bleed into the other). Lineage lands in the `scene_forks` read model
  (`Projectors.SceneForks`) for the branch navigator.

## 10. Ingestion & suggestion (§11)

- `Polyphony.Ingest` (+ `HeuristicSegmenter`): user prose → segments → `TurnPacket`,
  with a **verbatim integrity gate** (rewriting/reordering the user's words is
  rejected) and OOC routing (`[OOC: …]` → the Director, not a character move).
- `Polyphony.Suggest`: 2–3 candidate turn packets generated **from the acting
  character's filtered view** — suggestions can't leak what the character can't see.

## 11. Client broadcaster (§13)

`Polyphony.Broadcast` (pure fan-out) + `Broadcast.Publisher` (Commanded handler).
Each committed scene event publishes to **per-viewer PubSub topics**
(`scene:<id>:omniscient`, `scene:<id>:character:<id>`), filtered through the same
`visible_to?/3`. Framing (`beat.opened/closed`, `packet.superseded`) is
user/system-only and not part of the `event.committed` cursor. Reconnecting clients
catch up via `Broadcast.replay/4`, which self-filters superseded packets. The
publisher derives membership from the stream, so it needs no Postgres (safe under the
test sandbox).

## 12. Scene close (§8, §10)

`Polyphony.SceneClose` fans out on close into per-unit **retryable Oban jobs**
(`Jobs.SummarizeScene`, `Jobs.ExtractArc`): an omniscient summary plus one
**per-character summary from that viewer's filtered stream** (`Summarizer`),
embedded (pgvector) and stored scoped by character (`ReadModels.SceneSummary`); and
per-participant **arc extraction** (`ArcExtractor` → `:proposed` `ReadModels.ArcEntry`
for review). It **degrades rather than blocks** — a failed unit leaves that one
summary/arc missing; scene entry never waits on it.

## 13. Failures (§12)

`Polyphony.Failures` + `ReadModels.Failure`: terminal generation failures become
user-facing read-model rows broadcast as `generation.failed` with a `failure_id` and
affordances — **retry** (re-enqueue the exact work) and, for a refusal,
**edit-and-resubmit** (`retry_edited/2`). Never reaches a character; in-world they
simply didn't speak.

## 14. Authoring (§5–6, §15)

`Polyphony.Authoring.*`: `WorldBible`, `CharacterSheet`, `ArcEntry`,
`EffectiveSheet` (canon revisions override, discoveries union, in beat order). The
`Studio` generates a full sheet on the heavy model, then regenerates **field by
field** — locked fields are never touched and accepted/locked fields *are* the
context, so refinement converges. Workflow metadata (status/feedback/provenance)
lives in `FieldStore`, deliberately **out of** the generation schema
(`DraftSchema`) so the model generates character, not workflow.

## 15. Ownership, publishing & forks (§B1)

`Polyphony.Library` is the ownership layer over authored entities — character
sheets, world bibles, campaigns, prompt-template overrides — in `library_entries`.
**Owner is an indirection** (`Polyphony.Owner`, a `{type, id}` value; decisions §P2/§P8):
the table stores `owner_type` + `owner_id`, and the API takes an `Owner`, a `%User{}`,
or a bare id (coerced to `:user`, the v1 default). Every owner is a user in v1, but the
shape is polymorphic so orgs are a later "add an owner type + permission layer" bolt-on,
not a schema migration. `Library.Access` treats a *user*-owned entry as owned by the
matching actor and **default-denies** an org-typed entry until that permission layer
exists. Only content ownership is polymorphic — actor/reporter/recipient references
elsewhere stay user-shaped.
**Arc is not owned here**; it is campaign-scoped and travels *inside* a published
campaign. Two axes are deliberately independent: **visibility** (`private` /
`unlisted` / `public`) and **live/frozen** (references the owner's working set vs.
embeds pinned copies). Publishing implies freeze, but they stay separate properties.

Access is the pure, default-deny `Library.Access` predicate — the same discipline
`Visibility` applies to fiction: public reads for anyone (signed-out included),
unlisted needs the matching share token, private is owner-only, and **any write
requires auth + ownership** (a `nil` actor never writes). It operates on plain
structs, so it is tested without a database.

`Library.Snapshot` is the publish freeze: a self-contained copy embedding pinned
bible + sheet **versions** and a **canon-only** arc clipped to the published beat
(`include_proposed:` opts the proposed tail in). `omniscient_log/1` routes a scene's
events through `Visibility.project(_, :omniscient)`, so a published campaign exposes
the omniscient story — private thoughts, whispers, both arcs — never a raw firehose.

Copy-on-write mirrors the fork family (§9): `instantiate_character` copies a **sheet
only**, version-pinned; `fork_campaign` copies a whole published campaign *including
its arc snapshot* and re-owns the embedded bible + characters as new private,
fully-editable entries. Every derived entry keeps a `derived_from` (id + version)
pointer for attribution, and nothing locks forked content — everything is editable,
including private fields. HTTP/token plumbing and real `owner_id`s arrive with the
web/auth layer (B2); the domain core here is complete and tested offline.

## 16. Accounts — identity, roles, invites, consent (§B2)

`Polyphony.Accounts` is the account domain the ownership layer (§15) attributes
entities to. It is the **offline-testable core of auth** — everything that decides
*who may do what*; magic-link login tokens, sessions with sliding renewal, and the
numeric-code fallback are transport that belongs with the web layer.

Sign-up (`register/2`) is a single gated path enforcing three preconditions in
order: an **18+ attestation** (logged; its presence is the §A5 content floor, read
via `adult_attested?/1`), a **valid single-use invite** (the very first account
bypasses and bootstraps as `superadmin`), and acceptance of the **current consent**
documents. `Accounts.Consent` holds the current versions as the source of truth and
logs acceptance append-only, so `needs_reconsent?/2` re-prompts when a document's
version is bumped.

Roles (`Accounts.Roles`) are pure and default-deny: `:user` < `:admin` <
`:superadmin`. The first sign-up is the sole superadmin — pinned by a partial unique
index (`one_superadmin`) so even a race can't mint a second — and it is un-demotable
(even by itself) and never assignable by promotion. Admins and the superadmin may
promote a user to admin; only the superadmin may demote. Invites mirror this:
`create_invite/2` is admin-gated and each redeems exactly once — except a `reusable: true`
one, which stays valid after redemption for hands-on testing and is the reason
`revoke_invite/3` exists (an invite that never spends itself is a standing hole in the
gate, and revoking closes either kind without deleting the row). Real `owner_id`s for
§B1 fall out of this once the web layer authenticates a session.

## 17. Moderation — reporting, admin authz, audit (§B3)

`Polyphony.Moderation` sits on the roles (§16) and ownership (§15) layers. Two
guarantees hold across every function and are what the tests hammer:

- **Server-side authorization, never UI-only.** Each resolution action runs through
  one `with_admin/6` gate: a non-admin caller gets `{:error, :forbidden}` and **no
  side effect** — no state change and, critically, no audit row for an action that
  never happened.
- **Audited and attributed.** Each *successful* admin action writes exactly one
  `AuditLog` row — the append-only admin trail — and **any access to user content**
  (`content_access`, the §C reactive grant a report unlocks) is logged there too, so
  proactive/reactive access is always accountable.

Filing a report is a *user* action (an authenticated `%User{}` reporter); its reason
categories lead with the two absolute lines (CSAM, real-person sexual content,
`Report.absolute_line?/1`). A new report fires the admin alert through the pluggable
`Notifier` — the one live notification wire in v1, defaulting to a logging adapter
that B4 swaps for real email without touching moderation logic. Resolution actions —
take down (unpublish via `Library`, reason recorded for the owner; an absolute-line
takedown also **flags the owning account**, not just the item), dismiss, warn,
suspend — are all admin-gated and audited. Suspension and the review flag live on the
account (`Accounts.suspended?/1`, `flagged_for_review?/1`); the login gate itself is
the web layer's.

## 18. Notifications (§B4)

`Polyphony.Notifications` is the (deliberately minimal) sending path. A delivery
flows: resolve the recipient (a `%User{}`, id, or email) → check `Prefs` unless
`force:` → render a subject/body for the type → hand to the pluggable `Transport` →
record a `Notification` row with its status (`sent` / `skipped_opt_out` / `failed`).
Transport is **email only** in v1 and defaults to a logging adapter, so the whole
path runs and is tested offline with no egress; a real email adapter is a config
swap. Preferences are an **opt-out** stub surface — a row exists only for a type a
user turned off — present so deferred subscription types have a home.

v1 has exactly one live trigger, and it closes the loop from §17:
`Notifications.ModerationNotifier` (the configured `moderation_notifier`) implements
the B3 `Notifier` behaviour by fanning a new report out to every admin via
`notify_admins/3`, `force:`d past preferences because it is safety work. Swapping in
real email touches only config, never the moderation or notification logic.

## 19. Web layer — Phoenix LiveView (frontend)

`PolyphonyWeb` is a thin LiveView layer over the domain — no business logic; it
surfaces the contexts and enforces nothing they don't. Phoenix 1.8 / LiveView 1.2 on
Cowboy (OTP 27 / Elixir 1.17), with a real esbuild + Tailwind asset build whose
outputs are committed so it still serves with no build step. See `docs/frontend.md`
for running it.

Three things connect it to the guarantees the backend protects:

- **Viewer-parameterized rendering.** The Play view (`PlayLive`) renders a scene as
  `Broadcast.replay`/`Visibility.project` for a chosen viewer — omniscient or any
  character — and streams live off the §13 per-viewer broadcaster. A whisper a viewer
  wasn't part of is silently absent; a LiveView test pins that end-to-end, so the
  dramatic-irony guarantee holds *through the UI*, not just in the domain.
- **Auth is transport only** (`PolyphonyWeb.Auth`): a magic-link `Phoenix.Token`
  delivered through the §B4 notification path, verified into a session that carries
  only the user id. `on_mount` hooks gate the authed/admin live sessions; the domain
  (`Accounts`) still decides every permission.
- **Ownership through `Owner`.** Every library read/write is scoped by
  `Owner.of(current_user)` (§15), never a raw user id — the seam that keeps org
  support a bolt-on.

## 20. Deployment posture

Polyphony ships as a self-contained OTP release (`mix release`), built by the repo
`Dockerfile` and deployed to **DigitalOcean App Platform** via `.do/app.yaml`. A
`PRE_DEPLOY` job runs `Polyphony.Release.migrate/0` (read-model migrations + creation
of the `eventstore` schema and tables), then the web service boots. One managed
Postgres 16 cluster backs both the read models (`public`) and the persistent event
store (`eventstore` schema); `DEEPINFRA_API_KEY` + model routing come from env. The
full walkthrough is in `docs/deployment.md`.
