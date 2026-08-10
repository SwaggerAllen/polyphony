# Backend Capability Catalog

An inventory of **what the backend can do**, mapped to **whether it's surfaced in the
frontend** — the reference for designing views without missing built functionality.
Compiled from a full survey of `lib/polyphony/` cross-referenced against
`lib/polyphony_web/`. `§n` refs point at the design brief (see moduledocs).

**Status legend**

- ✅ **Surfaced** — a user-facing control/view exists.
- ◐ **Partial** — some of the capability is reachable; part isn't (noted).
- ✗ **Backend-only** — implemented (and usually tested) with **no UI**.

> The single most important section for information architecture is **§12. The Gap
> Register** at the bottom: every backend-only or partial capability in one list. That
> is the "don't forget to design a surface for this" checklist.

---

## 1. Domain & event model (§7, §8)

The event log is the single source of truth; corrections are new events. Character
events carry `beat` (grouping label, *not* an ordering key), `packet_id`
(`scene-beat-character`), and `seq` (move order).

### Events — `lib/polyphony/events.ex`

| Event | Meaning | Visibility (§8) | Status |
|---|---|---|---|
| `ThoughtOccurred` | interior monologue (`edited` = hand-authored) | self only | ✅ rendered |
| `PrivateStateReported` | private SelfState (`mood_felt`, `intention`) | self only | ✅ rendered |
| `SpeechUttered` | spoken move; `:private` audibility = whisper | whisper→speaker+addressees; else members-at-beat | ✅ rendered/composer |
| `ActionTaken` | physical action | members at beat | ✅ rendered |
| `DemeanorReported` | observable SelfState (demeanor/posture/position/attending) | members at beat | ✅ rendered |
| `WorldEventOccurred` | Director-authored occurrence / in-fiction rejection | members at beat | ◐ rendered; authored only by Director loop |
| `PacketSuperseded` | packet no longer canonical (reroll/edit/delete) | user & system | ✅ via reroll/delete/edit |
| `SceneOpened` / `SceneClosed` | scene lifecycle | default-deny | ◐ open via Start-scene; **close not a control** |
| `ControlModeSet` | who drives a character | user & system | ✅ cast panel |
| `TurnOrderDeclared` | authoritative per-beat cast order | user & system | ◐ set implicitly at Continue |
| `SceneForked` | first event of a fork/branch | default-deny | ✗ no branch UI |
| `CharacterEntered` / `CharacterExited` | membership change | members at beat | ◐ via intro-admit / Director casting |
| `IntroductionProposed` / `IntroductionDismissed` | Director wants to bring someone on | omniscient-only (explicit deny) | ✅ intro queue |
| `BeatOpened` / `BeatClosed` | pacing/§12 sync join | user & system | ◐ progress indicator only |
| `PacketRecorded` / `PacketFailed` / `PacketPassed` | §12 beat bookkeeping | mixed | ◐ failure→retry UI; rest internal |
| `GenerationFailed` | terminal generation failure | user only, never characters | ✅ inline failure UI |
| `ArcEntryProposed` / `ArcEntryAccepted` | scene-close interpreted facts | authoring metadata | ✅ Arc Review page |

### Aggregates, commands, projections

- **`Scene`** (`scene.ex`, §6.5) — lifecycle + membership arbiter; commands `OpenScene`,
  `EnterCharacter`/`ExitCharacter`, `CloseScene`, `RecordWorldEvent`,
  `ProposeIntroduction`/`DismissIntroduction`, `CommitPacket` (decomposes a packet into
  typed events, idempotent on `packet_id`), `SupersedePacket`, `ForkScene`,
  `SetControlMode`, `DeclareTurnOrder`. **No LLM in the aggregate** (rule 1).
- **`Director.Beat`** (`director/beat.ex`, §12) — beat synchronization unit (not atomic);
  `OpenBeat`, `RecordPacket`, `RecordFailure`, `RecordPass`, `CloseBeat`; `settled?/1`.
- **Visibility** (`visibility.ex`, §8/§13) — `visible_to?/3` is the one predicate; default-
  deny (`_ -> false`); membership judged **at the event's beat** via a swappable oracle
  (pure `MembershipSet` ↔ Postgres `ReadModels.Membership`, pinned by parity test).
  ✅ Play view is viewer-parameterized (`?as=`, `view_as`); the broadcaster routes every
  event through the same predicate.
- **Membership** (`membership_set.ex`, `read_models/membership.ex`, §8) — half-open
  intervals `[entered, exited)`; `member_at?`, `members_at`.
- **Packets & canonical** (`packets.ex`, §7) — `canonical/1` drops superseded packets +
  markers; every fiction-facing read goes through it. `beat_tail/3` = the turns a reroll
  invalidates.

### Timeline editing primitives

| Capability | Module | Status |
|---|---|---|
| **Reroll** (regenerate a turn + its beat tail, latest beat only) | `Polyphony.Reroll.reroll/4` | ✅ "Reroll" (omniscient) |
| **Delete** (supersede a turn out of canon) | `SupersedePacket` via `delete_turn` | ✅ "Delete" |
| **Edit — in place** (supersede + recommit `edited:true`) | `play_live.ex save_edit` | ✅ inline edit |
| **Edit — invalid/fork** (edit that invalidates the tail → branches) | `Polyphony.Edit.edit/6` (`:invalid`) | ✗ **backend-only** |
| **Fork / branch-from-here** (copy-on-fork alternate timeline) | `Polyphony.Branching.branch_from/4` over `Polyphony.Fork.fork/3` | ✅ "⑂ Branch" on play's beat dividers (STR-8) |
| **Branch navigator / lineage** (FS V2) | `Polyphony.Branching` + `ReadModels.Branch` (tree, canonical, cursor, tombstones) | ✅ campaign hub selector + full-screen navigator (STR-8) |

---

## 2. Play runtime — beat loop & broadcaster (§10, §12, §13)

- **Beat loop** — `Jobs.RunBeat` (one Director judgment/beat → apply plan → cast walk),
  `Director.BeatDriver.advance/3`, `BeatWalk` (next actionable slot + control mode),
  `BeatPolicy` (truncate > yield > continue; depth cap ≈3). ✅ kicked by **Continue**.
  ◐ **Continue is hardwired to single-beat yield** — the autonomous multi-beat "Play/Auto"
  pacing (depth-cap chaining) exists but has no control (roadmap).
- **Control modes** (§A1/§A2) — `autonomous` / `assisted` / `user_controlled`. ✅ cast panel.
  ◐ **`assisted` (draft & approve) has no draft accept/discard affordance** in the play view
  (`Drafts` + `BeatDriver.accept_draft/discard_draft` exist). ◐ **no explicit "pass turn"** button
  (`BeatDriver.pass_turn` exists).
- **Director decision** (`director.ex`, §10) — two-stage: pure Stage-1 arbitration
  (`Arbitration.classify`), then one JSON Stage-2 judgment (`Decision` schema: control,
  cast+pacing-notes, world_events, proposal_rulings, `scene_actions` open/close/move,
  introductions, `search_need`). ✗ arbitration, fairness (`Fairness.least_spoken_first`),
  proposals, `scene_actions`, `search_need` are all internal — no author controls.
- **Introductions** (§B7) — ✅ admit / generate-&-admit / edit / dismiss queue.
- **Progress** — `Broadcast.announce_progress` phases `:director|:generating|:awaiting_user|:idle`.
  ✅ busy indicator + input blocking.
- **Broadcaster** (`broadcast.ex`, §13) — per-viewer topics, `fan_out`, `replay` (canonical
  catch-up on reconnect), progress topic. Transport can't leak more than the projection.

---

## 3. Generation & LLM (§2, §3, §9)

- **Metering chokepoint** — `LLM.call/2` (`llm.ex`): every provider call routes here;
  resolves provider, records estimated cost, traces. ✗ internal seam.
  - **Circuit breaker** — `LLM.allowed?` → `Costs.allow?` → `{:error, :cost_cap_reached}`.
    ✅ error surfaced in play; ◐ **no resume / raise-cap control**.
  - **Force-heavy** debug lever (`DebugFlags`). ◐ debug drawer only.
  - **Trace capture** — `DebugTap` per-scene ring buffer. ◐ play debug pane (Trace flag).
- **Providers** — `Provider` behaviour; `DeepInfra` (OpenAI-compatible via `:httpc`):
  thinking on/off, **JSON-mode allowlist** (`@json_responses`), **service tiers**
  standard/priority/flex, retry+backoff on 429/5xx/transport, empty-response detection
  (Qwen quirk). `Mock` (offline lorem), `Stub` (tests). ✗ all config-only.
- **Per-campaign LLM settings** (`llm/settings.ex`, §9) — director thinking, director/character
  max tokens, workhorse/heavy model override, **service tier**. ✅ campaign "Model tuning".
- **Turn generation** — `Jobs.GeneratePacket` (the only place a turn generates; standalone /
  chained-autonomous / chained-assisted-draft), `Generation.generate` (generate→refusal-
  detect→decode→schema-validate→bounded self-correct), refusal→heavy-model retry,
  `PacketSchema` (moves 1..5). ✗ internal; failures surface via retry.
- **Ingestion** (`ingest.ex`, §11) — turn a human's prose into a packet by
  segmenting/classifying (never generating): `propose` → review → `confirm`, verbatim-
  integrity guard, OOC routing, self-state carry-forward. ✗ **entire pipeline backend-only**;
  the composer uses the lighter web-local `SayParser` instead.
- **Suggestion mode** (`suggest.ex`, §11) — 2–3 editable next-turn variants from the
  character's **filtered** view. ✅ ✨ Expand in the composer (drafts, never auto-committed).

---

## 4. Authoring (§6.1, §6.7, §15, §B8)

### Data model

- **CharacterSheet** (`character_sheet.ex`) — `name`, `premise`, `appearance`, `voice`,
  `temperament`, `backstory`; `facts` (**`core`** = always-resident vs long-tail retrieved),
  `initial_knowledge` (t=0 dramatic irony), `relationships` (directional; `target_id`,
  `descriptor`, `reciprocal`), `boundaries` (stance/condition/on_pressure/category),
  `status` (`:stub|:proposed|:full`), `role`, `world_bible_id`. ✅ sheet editor.
  ◐ the **`core` flag's caching meaning** (resident vs retrieved) isn't explained/visualized.
- **WorldBible** (`world_bible.ex`) — setting/tone/rules/starting_canon. ✅ bible editor.
- **Stub** (`stub.ex`) — a `:stub` CharacterSheet; reads "pending", finalizes on save. ✅.

### Autofill — `authoring/autofill.ex` (all ✅ except noted)

| Fn | Does | Surface |
|---|---|---|
| `generate_all` | brief → every field | ✅ "Generate all fields" |
| `generate_field` | regenerate one field | ✅ per-field |
| `generate_paragraph` | write/rewrite one paragraph | ✅ block editor |
| `suggest_relationships` | propose people known | ✅ ✨ Suggest |
| `suggest_boundaries` | propose conditional slow-burn lines | ✅ ✨ Suggest |
| `generate_campaign_premise` | write/deepen the pitch | ✅ premise ✨ Expand |
| `extract_mentions` | pull names from committed prose | ✅ Find-mentioned (play) |
| `reciprocal_roles` | the other side's regard | ✅ async on stub seed |
| `regard_map` | cross-link a cast | ◐ **only via QuickBuild**, no standalone button |

Context opts threaded through generation: `:world`, `:relations`, `:role`.

- **QuickBuild** (`quick_build.ex`) — one-shot world + cast (grounded in cast-so-far) +
  off-screen stubs + cross-links + premise, with progress + graceful degradation. ✅.
- **Review-gated pipeline** — `Studio` (generate + per-field accept/lock/feedback +
  provenance), `FieldStore` (`authoring_fields` state machine), `DraftSchema`. ✗
  **entire pipeline backend-only**; editors use the simpler Autofill path.
- **Stub promotion** — `StubGen.finalize` (generate a stub's full sheet). ✅ bulk
  "generate pending" + play "generate & admit".
- **Arc** — `ArcEntry` (discovery/revision, proposed→canon→retracted), scene-close
  `ArcExtractor`, `EffectiveSheet.apply` (canon arc → effective sheet). ✅ **Arc Review**
  (`/arc/:campaign_id`) — **accept only** (no reject/retract/edit; effective-sheet diff not
  shown). ◐ **Arc Review has no link from any other view** (unreachable in normal nav).

---

## 5. Content governance (§A5)

Three nested layers; effective register = `floor ∩ campaign_enabled`; a categorized
boundary the register disables is forced `:closed` at assembly.

| Layer | Capability | Module | Status |
|---|---|---|---|
| 1 | **18+ floor** | `Content.Floor.register/1` | ◐ **NOT wired to attestation** — `attested: true` hardcoded everywhere; signup captures `attested_adult` but the floor never reads it, so layer 1 is currently a no-op ceiling |
| 2 | **Per-campaign config** (adult master + sexual/graphic_violence/other) | `Content.CampaignConfig` | ✅ campaign "content ceiling" toggles + live label |
| 2→3 | **`gate_boundary`** (runtime cap) | `content.ex` | ✗ resolution not shown; editor shows a static "capped by" hint only |
| 2→3 | **`constrain_boundary`** (authoring-time cap, §V8a) | `content.ex` | ✗ **zero callers** — editor lets you set any category regardless of the campaign ceiling |
| 3 | **BoundaryGate** (conditional release vs canon arc, fail-closed, LLM evaluator) | `authoring/boundary_gate.ex` | ✗ resolved released/held state never shown to author or player |

---

## 6. Context assembly & memory (§9)

All **backend-only** (no UI renders the assembled context, and the tuning knobs aren't
exposed):

- **`Context.materialize`** — frozen per-character prefix, ordered stable→volatile for
  prefix-cache hits (world → sheet → content register → resolved boundaries → core facts →
  retrieved long-tail → distant summaries → verbatim recent scenes). ✗
- **`Context.Store`** (ETS cache) + **`Context.Rebuild`** (durable cold-cache rebuild on
  node restart, re-applies the content ceiling). ✗ no cache visibility/metrics.
- **Retrievers** — `Retriever` behaviour, `StaticRetriever` (default), `PgvectorRetriever`
  (embeds premise, searches that character's own summaries; metered). ✗
- **Per-character summaries** — `ReadModels.SceneSummary` (`character_scene_summaries`,
  character-scoped in the query itself). ✗ never browsable/editable.
- **Embeddings** — `Embeddings.embed` (metered). ✗
- **Director brief** — `SceneBrief.materialize/messages` (omniscient counterpart; frozen;
  full unfiltered budgeted transcript). ✗
- **Tuning** — `:fact_limit`, `:summary_limit`, `:scene_token_budget` (6000),
  `@transcript_token_budget` (4000). ✗ backend defaults only, not configurable.

---

## 7. Library, ownership & publish lifecycle (§B1, §B9)

- **Owner / LibraryEntry / Library** — owner-scoped entries (`character|world_bible|campaign|
  template_override`); two axes: **visibility** (private/unlisted/public) and **live/frozen**.
  ✅ create (per-type buttons), edit (save), list, filter/search, visibility select.
- **Share links** — unlisted mints a `share_token`; `ShareLive` (`/s/:token`) resolves it.
  ◐ **half-wired** — nothing generates/shows/copies the `/s/:token` URL after you go unlisted.
- **Access predicate** — `Library.Access.can_read?/can_write?`. ✗ defined but **not called by
  any LiveView** (views rely on route auth + token lookup) — confirm it's not an authz gap.
- **Publish** — `publish_campaign` → frozen `Snapshot` (pinned bible + sheet versions +
  canon arc + content ceiling); `Browse` (`/browse`) / `ShareLive` list public entries.
  ◐ **Publish works but has no consumer view** — Browse shows bare title cards; no
  read/play/fork of a published snapshot.
- **Copy-on-instantiate** — `instantiate_character` (copy a shared sheet into your library). ✗ no "Use this character" button.
- **Fork campaign** — `fork_campaign` (copy a published campaign incl. arc). ✗ no "Fork" button.
- **`derived_from` attribution** — stored on every derived entry. ✗ never displayed.
- **Soft-delete lifecycle** (§B9) — `archive` ✅, `soft_delete` ✅, but **`unarchive`,
  `restore`, `purge` are ✗** — no trash/recovery view; archived/deleted entries are
  unreachable (the recovery-window promise has no frontend). ◐ `list_for_owner`
  `:include_archived`/`:include_deleted` opts not exposed.

---

## 8. Scene close, failures, costs (§8, §12, §B5)

- **Scene close** — `SceneClose.enqueue` fans out into retryable jobs: N+1 visibility-
  filtered summaries + per-participant arc extraction. ✗ **NOT WIRED** — `enqueue` has no
  caller and the `SceneClosed` event doesn't trigger it, so **Arc Review and summaries are
  never populated in production**. (The whole memory/arc pipeline is dark until this is wired.)
- **Failures** (`failures.ex`, §12) — record + broadcast `generation.failed`; fields
  beat/subject/operation/kind/reason/editable/retryable/args. ✅ inline "Retry" (omniscient
  only). ◐ **`retry_edited` (edit-and-resubmit a refusal) has no UI**. ◐ **only the
  omniscient viewer sees failures** — a second human playing a character sees none.
- **Costs** (`costs.ex`, §B5) — per-user + per-campaign ledger; two ceilings (rolling
  daily/user + lifetime/campaign); `Attribution.for_scene` bills autonomous spend to the
  campaign owner. ✅ Settings shows **per-user 24h spend** only. ◐ **per-campaign spend
  (`spent_campaign`) not shown**; ◐ **no cap-configuration UI** (caps referenced in error
  copy but not editable); warn/stop states not surfaced.

---

## 9. Accounts, auth, moderation, admin (§B2, §B3, §B4)

- **Accounts** — gated signup (18+ attestation + invite + versioned consent), magic-link
  passwordless login, sliding sessions, route guards (`:public|:authed|:admin`), profile
  edit, rate-limited username change (1/30d), proactive-analysis opt-out (§C). ✅ signup /
  login / settings.
- **Roles** — user/admin/superadmin; first account = sole superadmin (DB-pinned). ✅ admin
  "promote to admin". ◐ **demotion / reinstatement not surfaced**.
- **Invites** — single-use, admin-minted. ✅ admin.
- **Moderation** (`moderation.ex`, §B3/§B4) — report queue + take-down/dismiss/suspend/warn/
  view-in-context, all authorized + audited (`AuditLog`, `Notifier`). ✅ `/admin`.
  ◐ **no user-facing "Report" action** anywhere (Play/Browse/Share) — the intake path is
  backend-only.
- **Debug drawer** — server log stream + force-heavy/events/trace toggles; play debug
  timeline. ◐ gated behind `DEBUG_DRAWER` env, not general UI.
- **Ops** — `Release` (migrations), bootstrap cleanup, `ShutdownHook`. ✗ CLI/release only.

---

## 10. Background jobs (Oban)

Queues: `generation: 5, director: 2, scene_close: 3`. Four workers:

| Worker | Queue | Role |
|---|---|---|
| `RunBeat` | director | beat coordinator (Director judgment → membership → walk) |
| `GeneratePacket` | generation | the only turn-generation site (standalone / autonomous / assisted-draft) |
| `SummarizeScene` | scene_close | one viewer's scene summary (retry-to-exhaustion) |
| `ExtractArc` | scene_close | one participant's arc extraction (schema-invalid = permanent) |

---

## 11. Orphaned / suspect abstractions (confirm intent)

- **`AutofillControls`** component — expects a `:draft` assign; both real editors roll their
  own `Autofill.*` async instead. Looks superseded.
- **`Library.Access`** — pure predicate, unused by any LiveView (authz relies on route guards
  + token lookup). Confirm not a gap.
- **`Content.constrain_boundary`** — implemented, zero callers.

---

## 12. The Gap Register — backend capability with no / partial UI

The design checklist. Each line is a place where the backend can do something the
frontend can't (yet) reach.

### Timeline / play
- ✅ **Fork / branch-from-here** + **branch navigator** — shipped as STR-8:
  `Polyphony.Branching` over `Fork.fork/3`, the ⑂ control on play's dividers, and the
  hub's selector + full-screen navigator (canonical, archive, re-parenting delete,
  tombstones, divergence cursor). Still open from that ticket: the reader's
  off-canon / diverged / gone states are built and storybook-pinned but not yet
  driven by publication data.
- ✗ **Edit-as-fork** (`Edit.edit` `:invalid`) — no "this changes history, branch it?" flow.
- ◐ **Autonomous multi-beat pacing** — Continue is single-beat only; no Play/Auto mode.
- ◐ **`assisted` draft accept/discard** — mode selectable but no draft affordance.
- ◐ **Explicit "pass turn"** for a user-controlled slot.
- ✗ Director internals with no author lever: **fairness**, **proposals**, **`scene_actions`
  (open/close/move)**, **`search_need`**.
- ◐ **World events** authored only by the Director — no direct author "narrate" control.
- ◐ **Mid-scene add/remove character** (`SceneControl.add_character/remove_character`) — only
  reachable via intro-admit, not a direct control.

### Authoring / memory
- ✗ **Studio review-gated pipeline** (accept/lock/feedback/provenance per field) — entirely unwired.
- ✗ **Full ingestion** (`Ingest` propose→review→confirm, verbatim/OOC) — composer uses `SayParser`.
- ◐ **`regard_map`** — no standalone "cross-link" button (QuickBuild only).
- ◐ **Arc Review unreachable** (no nav link) and **accept-only** (no reject/retract/edit;
  effective-sheet diff not shown).
- ✗ **BoundaryGate resolution** (released/held per scene) never shown.
- ◐ **`core` fact flag** — caching meaning not surfaced.

### Content governance
- ◐ **18+ floor ↔ attestation disconnect** — attestation captured, never read by the floor.
- ✗ **`constrain_boundary`** authoring-time ceiling enforcement — not called; editor allows
  any category past the ceiling.
- ✗ **Resolved content register / boundaries** never rendered to author or player.

### Library / publish / lifecycle
- ◐ **Share-link URL** never generated/shown after going unlisted.
- ✗ **Fork campaign** / ✗ **instantiate character** — no "Fork" / "Use this" buttons.
- ◐ **Publish has no consumer view** — Browse = bare title cards; no read/play/fork of a snapshot.
- ✗ **derived-from attribution** never displayed.
- ✗ **unarchive / restore / purge** — no trash/recovery view; ◐ no "show archived" toggle.

### Scene close / failures / costs
- ✗ **Scene-close fan-out never triggered** — `SceneClose.enqueue` has no caller; **arc &
  summaries are dark in production** until wired to `SceneClosed`. *(High priority — it
  silently disables the entire memory/arc layer.)*
- ◐ **`retry_edited`** (edit-and-resubmit a refusal) — plain Retry only.
- ◐ **Failures visible to omniscient only** — character players see none.
- ◐ **Per-campaign cost view** + **editable caps** + **warn/resume** — only per-user 24h spend shown.

### Accounts / moderation
- ◐ **No user-facing "Report"** intake anywhere.
- ◐ **Role demotion / account reinstatement** not surfaced.

### Config knobs (no UI, backend defaults only)
- ✗ Retrieval/token tuning: `fact_limit`, `summary_limit`, `scene_token_budget`,
  transcript budget, retriever/embedder choice, cost rate.
- ◐ Debug levers (force-heavy / trace / events) behind `DEBUG_DRAWER`.

---

*Generated from a subsystem-by-subsystem code survey. When a view is designed, check it
against §12 so a built-but-unsurfaced capability gets a home (or a deliberate "later").*
