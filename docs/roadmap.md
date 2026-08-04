# Polyphony — Roadmap

What's built, what's next, and the deferred seams. References: the design brief
(§n), the **backend delta** (§A/§B/§C), and the **frontend spec** (FS Vn). See
`architecture.md` for how the shipped parts work.

---

## Done (backend)

Design-brief build order (§15) slices 1–9, plus the branching family:

- Event store + aggregates + **visibility projection** (the core guarantee)
- Scene + membership **interval read model** (pure + Postgres parity)
- Provider boundary + structured generation → `CommitPacket` (Oban)
- Context assembler (stable→volatile prefix caching) + authored layer
- Director: arbitration, judgment, beat loop, lifecycle aggregate, runner (inline
  + Oban-driven)
- User's agent: prose ingestion + verbatim gate, suggestion mode
- Scene-close pipeline: per-character pgvector summaries + arc extraction
- Per-viewer broadcaster (§13) + beat framing + user-facing failures
- Authoring: character generation + field-level regeneration
- **Re-rolls** (in-beat supersession), **forks** (copy-on-fork streams), **edits**
  (§A4 — corrections with the downstream-validity choice)

Everything runs offline on `LLM.Mock`; the suite is green with no network.

---

## §A — Amendments (revise shipped behavior)

- **A1 — Multiple yields per beat + user-stipulated turn order.** ✅ **Done** (inline
  runner). Explicit `TurnOrderDeclared` / `ControlModeSet` on the scene log (§A1);
  the beat loop walks the declared order, generating autonomous slots and **yielding**
  on user-controlled ones (`submit_user_turn`/`pass_turn` resume — a beat can yield
  more than once); the Beat aggregate counts a `passed` slot as terminal; re-roll
  reads control modes so it never regenerates a user's turn. Turn order is
  authoritative — a user reorder or **removal** is honored. Also fixed a latent
  round-trip bug found here: atom-valued event fields (`SpeechUttered.audibility`)
  stringified through the JSON store, so a stored whisper leaked to non-addressees —
  now re-atomized via a `JsonDecoder`. The **Oban async path** honors control modes
  too (`Director.BeatDriver`), sharing the walk *decision* (`Director.BeatWalk`) with
  the inline runner so the two can't diverge.
- **A2 — Pending/draft state before commit.** ✅ **Done.** `Polyphony.Drafts` +
  `ReadModels.PacketDraft` — a pending-draft store kept **off the fiction log**
  entirely (like `Failures`), so a draft structurally can't reach `visible_to?`
  until accepted, at which point it's an ordinary `CommitPacket` (`edited: true` if
  the user edited it). Serves both **assisted** mode — wired into the A1 walk as
  generate-then-yield (`accept_draft`/`discard_draft` resume) — and **suggestion**
  mode (the composer's candidates are drafts with `source: "suggestion"`). Packet
  stored losslessly as an Erlang term; `draft.ready` broadcast to omniscient.
  Works on **both** loops — inline (`Runner.accept_draft`) and Oban async
  (`BeatDriver.accept_draft`).
- **A3 — Boundaries × conditional-arc evaluation.** ✅ **Done.** `boundaries` on
  `CharacterSheet` (`:open`/`:conditional`/`:closed` + condition + on_pressure);
  `Authoring.BoundaryGate` resolves each against the **canon arc** — `:open` released,
  `:closed` held, `:conditional` judged by a pluggable `Evaluator` (default `LLMEvaluator`,
  **fails closed** so an unjudgeable condition leaves the character guarded). The gate is
  evaluated at **scene open** and frozen into the prefix (arc only changes at scene close),
  and `Context.materialize` renders the resolved state **in character** — a refusal is
  generated as a scene beat, never a post-generation filter.
- **A4 — Editing.** ✅ **Done.**
- **A5 — Three nested content layers.** ✅ **Done.** `Polyphony.Content` governs three
  layers: `Content.Floor` (app-wide 18+ ceiling, non-configurable — attested ⇒ all
  categories, else none), `Content.CampaignConfig` (per-campaign `adult_content` master
  toggle gating sexual / graphic-violence / other sub-toggles), and per-character
  boundaries (§A3). `Content.register/2` is the nesting intersection `floor ∩ campaign`:
  a narrower layer restricts within a broader one and **never expands past it** (campaign
  off ⇒ no adult content regardless of any `:open` boundary). Enforced twice — at authoring
  (`constrain_boundary/2`, FS §V8a) and at context assembly (`gate_boundary/2` forces a
  disabled-category boundary closed *before* `BoundaryGate.resolve`, and the register is
  rendered into what both the Director and characters are told). Layers 2 and 3 stay
  conceptually separate: a boundary's optional `:category` is only the link that lets the
  ceiling cap it — a `nil`-category boundary is pure characterization the register never touches.

---

## §B — Additions (net-new surfaces)

- **B1 — Ownership, visibility, publish snapshot.** ✅ **Done (core).** `Polyphony.Library`
  owns authored entities (`character` / `world_bible` / `campaign` / `template_override`) in
  `library_entries`, with two independent axes: **visibility** (`:private` default / `:unlisted`
  share-token / `:public`) and **live/frozen**. Access is the pure default-deny
  `Library.Access` predicate (public reads for anyone incl. signed-out, unlisted needs the
  matching token, private is owner-only; **any write requires auth + ownership**).
  `Library.Snapshot` is the self-contained frozen copy — pinned bible + sheet versions +
  **canon-only arc** clipped to the published beat (`include_proposed:` opts the tail in), and
  `omniscient_log/1` guarantees the published view is the omniscient projection. Publishing
  freezes; `instantiate_character` copies the **sheet only**, version-pinned; `fork_campaign`
  copies the whole campaign incl. the arc snapshot and re-owns the embedded bible + characters
  as new private, fully-editable copies (`derived_from` attribution throughout). *Deferred to
  when the web/auth layer lands:* HTTP/token plumbing and wiring `owner_id` to real accounts
  (B2), and embedding full scene logs into published campaigns (the omniscient projection is
  ready; only the bulk copy is deferred).
- **B2 — Auth, identity, consent.** ✅ **Done (domain core).** `Polyphony.Accounts` +
  `Accounts.{User, Invite, Consent, Roles}`: identity (unique username distinct from
  auth-only email; profile fields; rate-limited username changes), a gated `register/2`
  enforcing all three sign-up preconditions offline — 18+ attestation (logged; the §A5
  content floor via `adult_attested?/1`), a valid single-use invite (first account
  bypasses), and current consent — plus versioned append-only consent with
  `needs_reconsent?/2` re-prompting on a version bump.
  - **[planned addition #4]** ✅ roles `user` / `admin` / **`superadmin`**: first sign-up
    → superadmin (pinned to a singleton by a partial unique index); pure `Roles`
    authorization — admins/superadmin promote to admin, superadmin alone demotes, and the
    superadmin is un-demotable (even by itself) and never assignable.
  - **[planned addition #5]** ✅ **invite-only sign-up** — `create_invite/2` is admin-gated,
    invites are single-use, and the first user bypasses. Free / subscription tiers remain a
    future addition.
  - *Deferred to the web/auth layer:* magic-link email delivery + numeric-code fallback,
    sessions with sliding renewal (transport). The domain that decides *who may do what* is
    complete and tested; only the login channel is deferred.
- **B3 — Admin, moderation, reporting.** ✅ **Done (domain core).** `Polyphony.Moderation`
  + `Moderation.{Report, AuditLog, Notifier}`. Two standing guarantees, tested hardest:
  **every admin action is server-side authorized** (a non-admin gets `:forbidden` with *no*
  side effect — no state change, no audit row) and **every successful admin action is audited
  and attributed** (one `AuditLog` row each, especially `content_access`). Reports (reporter
  auth required; reason categories lead with the CSAM / real-person-sexual absolute lines) fire
  the admin alert through a pluggable `Notifier` (the one live wire; real email is B4).
  Resolution actions — view-in-context (the §C reactive-access grant, audited), take down
  (unpublish + reason recorded, and an **absolute-line takedown flags the owning account**, not
  just the item), dismiss, warn, suspend — all gated + audited. Accounts gain `suspended_at` /
  `flagged_for_review_at` with predicates. *Deferred to the web/auth layer:* HTTP admin surface
  and the login suspension gate (the state + predicate are here).
- **B4 — Notification infrastructure (minimal).** ✅ **Done.** `Polyphony.Notifications` is
  the sending path: resolve recipient → check `Prefs` (unless `force:`) → render per type →
  hand to a pluggable `Transport` (email only; default logs, real email a config swap) →
  record a `Notification` row with status. Preferences are an **opt-out** stub surface
  (`Prefs.wants?/set`, a small type catalog; only `:report_alert` live). The one live trigger,
  B3's admin report alert, is wired through it: `Notifications.ModerationNotifier` (the default
  `moderation_notifier`) fans a report out to every admin, `force:`d past prefs since it is
  safety work. *Deferred to the web/auth layer:* the real email adapter and the preferences UI.
- **B5 — Cost caps / circuit breaker + per-user accounting.** ✅ **Done.** `Polyphony.Costs`
  over an append-only `cost_ledger` (billing-ready micro-cent units, per user + per campaign).
  `check/3` evaluates a rolling per-day cap and a lifetime per-campaign cap → `:ok` / `{:warn,…}`
  at the soft threshold / `{:stop,…}` past a ceiling; `allow?/3` is the circuit breaker the
  generation path consults so a stuck Director loop can't run unbounded. Caps from opts → config
  → defaults. **Metering is now wired on the autonomous path:** `Polyphony.LLM.call` books every
  chat call, and `Polyphony.Embeddings.embed` (the embed-path sibling) books every embedding;
  autonomous spend — the Director's decision (`kind: "director"`), the cast turns it drives
  (`"generation"`), and the memory embeddings (`"embedding"`) — is attributed to the **campaign
  owner** via `Polyphony.Costs.Attribution.for_scene/1` (scene → campaign → owner), so a job with
  no logged-in user still bills correctly. *Deferred:* consulting `allow?/3` as a pre-generation
  gate (the breaker exists but isn't yet enforced on the beat loop), attributing **user-submitted**
  turns (composer/suggestion) to the submitter, a separate embedding cost rate (embeddings reuse
  the generation rate for now), and the resume/raise-cap UI.
- **B6 — Export.** ✅ **Done.** `Polyphony.Export` (pure): `transcript/3` renders a scene's
  events to markdown, omniscient by default or **as a character** — the per-perspective export,
  which is just `Visibility.project/2`, so a character export structurally can't leak a whisper
  they weren't part of. `json/2` is the structured archive (omniscient log + pinned deps = the
  frozen snapshot); `entity_json/2` exports a sheet/bible. *Deferred:* the library/delete-confirm
  UI hooks that offer these.
- **B7 — Manual scene control + Continue.** ✅ **Done.** `Polyphony.SceneControl`:
  `add_character` / `remove_character` emit `CharacterEntered` / `CharacterExited` directly
  (author lever, bypassing Director casting), effective at the given beat boundary — the
  half-open `[entered, exited)` interval already guarantees no mid-packet change. Adding a
  `:stub` is refused (`{:error, :stub_needs_promotion}`) until promoted (§B8). `continue/3` is
  the empty user turn — kicks a beat run with no committed packet so the Director casts and
  proceeds (`:enqueue` injectable for tests). *Deferred:* the UI buttons.
  - **One-beat Continue vs. Auto/Play (⬜ planned).** A user Continue now advances **exactly
    one beat**: its `control_hint: "yield_to_user"` is honored as authoritative over the
    model's own `control` (`RunBeat.cap_to_one_beat/2`), so the loop can't self-chain a
    string of autonomous beats per click (membership truncation still runs — that re-decides
    the same exchange, capped by depth, not `control`). The autonomous multi-beat path is
    still fully built (the Director's `control: continue` + the `BeatPolicy` depth cap of 3);
    it just needs a deliberate **"Auto"/"Play" control** in the Play view that fires
    `continue` *without* the yield hint, letting the cast run up to the cap hands-free.
- **B8 — Character stubs.** ✅ **Done.** `CharacterSheet` gains `status: :stub | :proposed |
  :full` + a one-line `role`. `Polyphony.Authoring.Stub`: `new/3` makes a stub (name + role +
  inbound relationships, no sheet); `promote/2` generates a full sheet from the stub + context
  and gates it `:proposed` (pluggable `:generator`, default the LLM, so it runs offline);
  `accept/1` is the review gate → `:full`. Casting a non-`:full` character is refused by
  §B7 (`:stub_needs_promotion` / `:needs_promotion`). Mirrors locations' `origin: :discovered`.
  *Deferred:* the inline-create + promotion-review UI, and Director `:novel`-proposal stub creation.
- **B9 — Soft-delete.** ✅ **Done.** `Library` gains `archived_at` / `deleted_at`: `archive`
  hides from default lists (recoverable), `soft_delete` is a recoverable tombstone that
  **unpublishes** published content (visibility → private, resolving the snapshot), `restore`
  brings either back within the window, and `purge` is the hard, final delete. Owner/public lists
  exclude archived + deleted by default (`include_archived:` / `include_deleted:` opt in). Forks
  are independent copies — deleting/purging a published source never cascades to them. *Deferred:*
  the scheduled recovery-window auto-purge job and the delete-confirmation UI.
- **B10 — Authored plot triggers & scripted events.** ⬜ **Planned — not yet designed.** Worlds
  and campaigns need author-defined **triggers → events** so plot points can be baked in — e.g.
  "when the party reaches the ruins, the messenger arrives," "on beat N / when condition X holds,
  fire world event Y." The **Director must know about them**: evaluate trigger conditions during
  the beat loop and fire the scripted event as an ordinary world event (subject to default-deny
  visibility like anything else — scripted beats can carry dramatic irony too). Needs a place in
  the World Bible / campaign model to store them and an **authoring UI** (none exists yet).
  **Scope: world, character, and location.** Though framed at the world level, the same
  declarative trigger → event mechanism must apply at **character** and **location** scope
  too — a trigger can fire a *character* event (a revealed secret, a change of allegiance) or
  a *location* event (a description/state update, §B11), not only a world event. One trigger
  model, three target scopes.
  *Open questions:* the condition language (beat-count / state-predicate / location-entry /
  arc-milestone?); one-shot vs. repeatable; copy-on-fork behavior of a fired vs. unfired trigger;
  author-visible vs. player-hidden. Keep triggers **pure/declarative** so aggregates stay
  LLM-free (rule 1) — the Director *decides* to fire, a job *generates* any prose.
- **B11 — Locations as first-class arced entities.** ⬜ **Planned — not yet designed.**
  Locations exist as authored/discovered entities (`origin: :discovered`) but are static; they
  need parity with characters on two fronts. (a) **Location arcs** — a location changes over a
  campaign (the tavern burns down, the border closes), so scene-close should extract
  **per-location arc entries** the way it does per-character ones, reusing the existing
  summary → arc + supersede-and-recommit machinery rather than new plumbing. (b) A
  **location-description event type** — a first-class event that records/updates a location's
  description and state, so a location's *current* description is a **projection over the log**
  (like membership and everything else), not a static sheet field. Decide its `visible_to?`
  clause deliberately (rule 3) — who can perceive a location change depends on presence/
  knowledge, so this is not automatically public. Pairs with §B10 (a location-scoped trigger
  fires exactly this event) and feeds the deferred V7 Location Graph and boundary/arc
  evaluation the way character arcs do.
- **B12 — Split the Director actor from a World actor.** ⬜ **Planned — not yet designed.**
  **Sequence: after the locations authoring surface (§B11 / V7).** Today the Director *is* the
  world agent — one agent casts/paces the scene *and* is the sole holder of world knowledge
  (CLAUDE.md: "one agent per character plus a world agent ('Director')"). Split them: a **World
  actor** owns the whole world **outside** the scene — persistent, campaign-level world state
  that outlives any single scene (what's true, where things are, what's changed globally) —
  while the **Director** keeps a narrowly-focused **per-scene** omniscient context. `Polyphony.
  Director.SceneBrief` was built for exactly this shape (scene-scoped world framing + premise +
  cast + cross-scene summaries, *not* the whole world), so it's already the Director-side seam.
  Motivation: the Director's context should stay scene-tight for focus and cost; world-scale
  knowledge doesn't belong in every beat's prompt.
  *Interaction is the hard part (design later).* Leading candidate: the **Director calls the
  World as a skill/tool**, and the **World runs on scene transitions (open/close), not every
  beat** — so world-state updates are amortized at boundaries rather than paid per turn.
  Alternative (or complement): **bump the Director to the heavy model** so it can carry more
  context without a full split. These aren't mutually exclusive — a scene-tight Director on the
  workhorse tier that consults a heavier World at transitions may beat either alone. Pairs with
  §B10 (the World actor is the natural owner of world-scope triggers) and §B11 (world state
  includes where things are). Keep it aggregate-safe (rule 1): the World *decides/produces
  commands* in a job, aggregates stay LLM-free.
  *Open questions:* the World↔Director contract (skill-call shape; what the World returns into a
  scene); which world state is authored vs. emergent; how the World's cross-scene state relates
  to the event log and copy-on-fork; whether "World at transitions" vs. "heavy Director" is
  either/or or both.

---

## §C — Cross-cutting data-handling ✅ **Done (backend)**

Because content is stored unencrypted and the operator is a data controller:

- **Reactive vs proactive access split** ✅ — `Polyphony.DataAccess` enforces it at the
  data layer: `proactive_eligible?/3` / `proactive_scope/2` exclude an opted-out account
  *or* campaign from proactive scanning at query time, while `reactive_access/3` (a report
  grant) is a documented pass-through to B3's audited access that **never** consults the
  opt-out — a reported user cannot opt out of being investigated. Tested by the asymmetry:
  an opted-out account is dropped from proactive scope yet still reachable via a report.
- **Opt-out flags enforced at the data layer** ✅ — account opt-out on the user,
  per-campaign in `CampaignDataPrefs`, both applied in queries (`proactively_opted_out_user_ids/1`
  gives a scanner its exclusion set), not just UI.
- **Retention & deletion** ✅ (§B9) — real archive/soft-delete/restore/purge windows; forks
  survive. (Backups / legal holds remain ops concerns.)
- **Admin audit log** ✅ persisted (§B3), covering all content access (`content_access`).
- **Consent versioning** ✅ persisted (§B2), tied to policy versions.

---

## Planned additions (this session)

1. **User-stipulated turn order + character removal per beat** → folded into **A1**
   (explicit turn-order event; re-roll reads declared order).
2. **CLAUDE.md / architecture.md / this roadmap** → ✅ done.
3. **DigitalOcean App Platform deploy + setup doc** → ✅ done. OTP release +
   Dockerfile, `.do/app.yaml` (PRE_DEPLOY migrate job + web service), persistent event
   store in a dedicated `eventstore` schema on the managed Postgres, DeepInfra via
   `DEEPINFRA_API_KEY`/model routing. See `docs/deployment.md`.
4. **First-user auto-admin + `superadmin` role** → folded into **B2/B3**.
5. **Invite-only sign-up (single-use links)** → folded into **B2**.

---

## FE/BE parity audit 🔨 **Run once — findings below**

The same shape of bug keeps surfacing: a capability lives on **one** side only. Either
the backend has it with no way to reach it (boundary authoring, human-controlled
autogenerate, the cost circuit breaker — all now wired), or a subsystem is built and
tested but **never invoked** on the live path (pgvector retrieval defaulted to the
static retriever; the omniscient scene summary was written every close but never read;
embeddings and autonomous generation weren't metered; embeddings weren't even produced
by a real model). Each was found by accident, not by looking.

Do a **deliberate one-pass audit**: enumerate the backend surface (contexts, Oban jobs,
event types, read models, `Polyphony.*` public functions) against the LiveView surface
(views, `handle_event`s, what's actually called at runtime), and for every capability
that exists on one side only, either wire it or record it here as deliberately deferred
with the reason. Known one-sided items to start from: the deferred FS views (**V2**
Scene Index & Branch, **V3** Character Inspector, **V7** Location Graph, **V10.1**
prompt-template editor); backend features whose UI is flagged deferred in §B (**B5**
resume/raise-cap surface, **B6** export/download hooks, **B9** delete-confirmation flow,
**B4** notification-prefs UI); and the standing invariant that any *new* event type or
`Costs`/retrieval/generation seam gets checked for a live caller, not just a test.

### Findings, verified against the code (not against this document)

Each was checked by counting **production** callers, not test callers — a module with
seven test references and none in `lib/` is exactly the shape that reads as shipped. In
rough order of how much a user would notice:

| Capability | Backend | Frontend | What a user sees |
|---|---|---|---|
| **Assisted drafts** (§1.5) | ✅ | ✅ **now built** | — was: Continue stopped the beat and nothing appeared |
| **User-controlled turns** (§A1) | ✅ `submit_user_turn` / `pass_turn` | ❌ no caller | "I write their turns" has no interactive effect; speaking as a Director-driven character double-turns |
| **Group arc fan-out** (§3.0b) | ✅ `GroupArc.fan_out/3` | ⚠️ half — the review card reads `pending/2`, nothing calls `fan_out/3` | the collapsed group card can never populate |
| **Edit with tail invalidation** (§1.2) | ✅ `Edit.edit/6` | ❌ `PlayLive.save_edit` hand-rolls supersede+commit | no way to say "this changes what happened"; every edit is silently `:valid` |
| **Fork / branch from beat N** (§1.1) | ✅ `Fork.fork/3` | ❌ only reachable via `Edit`'s `:invalid` path, which nothing calls | a published story can be forked; your own scene can't be branched |
| **Draft editing before accepting** | ✅ `Drafts.edit/3` | ❌ no caller | the card takes or discards; it can't correct |
| **Scene location as an authored field** (§2.3) | ✅ `OpenScene` takes `location:` | ❌ never passed | a scene's location is always blank |
| **Notification preferences** (§B4) | ✅ `Notifications.Prefs` | ❌ no screen | opt-outs exist and are unreachable |
| **Export / download** (§B6) | ❌ | ❌ | not started either side — no gap, just absent |
| **Failed turns requeue to tail** (§1.4) | ❌ deferred by decision | — | a failed turn is retried in place |

Two documentation defects found in the same pass, both since corrected: `Polyphony.Groups`
claimed the audience picker and group fan-out were unbuilt (the picker shipped; `fan_out/3`
exists and is merely uncalled), and `backend-backlog.md` §1.5 still said the approve card
was deferred after it was built. **A moduledoc that under-claims is how a shipped feature
gets built twice**, so these are worth the same care as the code.

The standing rule this pass exists to enforce: a new event type, context function, or
`Costs`/retrieval/generation seam is not done when its test passes — it is done when
something on the live path calls it.

**Interactive user-controlled turns (backend-built, FE-unwired) — deliberately deferred.**
The beat loop fully supports a `user_controlled` slot: `BeatDriver` pauses at that
character (`awaiting.user` broadcast) and `submit_user_turn`/`pass_turn` resume the walk.
But the Play composer never consumes that pause — it always does a *free* `CommitPacket`
at `next_beat`, so setting a character to "I write their turns" has no interactive effect,
and speaking as a character the Director also drives produces a double turn. Wiring it
(surface the paused slot; route the composer's Send → `submit_user_turn`, add Pass; show
whose turn it is) is the path to "I play my character, the AI plays the rest" and to
multiplayer. Left as-is by choice for now — the workaround is to not speak as a character
you want the cast to drive.

---

## Frontend (LiveView) — FS view inventory

✅ **Done (core).** Phoenix 1.8 + LiveView 1.2 on OTP 27 / Elixir 1.17 (Cowboy, not
Bandit; a real esbuild + Tailwind build whose outputs are committed, so it still
serves with no build step). Principles held:
every event-rendering view is viewer-parameterized through `visible_to?` (the Play view
switches omniscient ↔ any character, and a whisper is silently absent for a bystander —
covered by a LiveView test); committed packets only; three distinct waiting states;
mobile-first. Auth is magic-link (no passwords) over the §B4 notification path; the session
carries only the user id; ownership everywhere flows through `Polyphony.Owner`. See
`docs/frontend.md` for how to run it.

Built: **V1 Play**, **V4 Sheet Editor** (+ stub promote/accept), **V5 Arc Review**, **V6
World Bible Editor**, **V8 Campaign Setup** + Campaign overview, **V9 Library** + public
Browse + unlisted Share, **V10/V12 Settings/Account/Cost**, **V11 Auth**, **V13 Admin &
Moderation**. *Deferred:* V2 Scene Index & Branch Navigator, V3 Character Inspector, V7
Location Graph, and the V10.1 prompt-template editor (`solid`/sandboxed Liquid) — plus the
autonomous-Director "Continue" is wired best-effort and wants a hardening pass under real
multi-beat play.

---

## Frontend redesign & design-kit fidelity 🔨 **In progress**

The current LiveView is the first-cut UI; the redesign is speced in `ux/` (mocks + the
`polyphony-kit.css`/`polyphony-kit.html` component kit). Three things to do:

- **Port from the kit directly, to keep design and implementation in lockstep.** ✅ **The
  foundation is built** — the kit's *tokens and classes* are now derived from `ux/` by
  `mix kit.port` rather than hand-copied, and its *markup* lives in `PolyphonyWeb.Kit` as
  function components. Detail in `completed-roadmap.md`. **Remaining: the screens.** Each
  one ports by calling those components instead of re-deriving class strings. The first-cut
  design system has been **deleted**, so **unported screens render unstyled until they're
  rebuilt** — an accepted cost, since the app has no users until the rebuild lands. Their
  LiveViews and tests stay until each replacement lands: they're the record of how a screen
  drives the domain, and the behaviour the new one must still satisfy. **Play is ported**
  (detail in `completed-roadmap.md`). Screens left to rebuild: campaign, sheet editor, world
  bible, arc review, library, browse, settings, admin — in `ux/README.md`'s own order. Play,
  the app shell and the campaign hub are done. The campaign's **Groups tab is unblocked but not
  yet built** — `Polyphony.Groups` now exists (see `completed-roadmap.md`); the tab is the next
  frontend piece. The **app shell is ported** — there is
  no global nav bar; a screen owns the viewport and carries `Kit.header/1` with the overflow
  menu. The backend prerequisites are the
  `backend-backlog.md` immediate milestone.

  Deferred out of the play port, each needing its own design surface or backend wiring:
  the **audience picker** (`ux/polyphony-audience-picker.html` — an explicit "say it to"
  control; the `(whisper to NAME: …)` syntax carries it meanwhile), **Pass / draft cards**
  (the A1 interactive-turn wiring the FE/BE parity audit already tracks as deferred), the
  redesigned **Introductions panel + character picker**, and the **Set the scene** screen.
- **Build the play view id-native (finishes the identity migration).** ✅ **Done.** The
  character-identity mint-flip (`backend-backlog.md §5.2`, phases 2b-emit + 3 + 4) landed
  here rather than overhaul-then-discard the current LiveView: characters enter by library
  id, emitted whisper names resolve to ids before commit, and the play view renders names
  at the edge. Pinned by `PlayIdentityLiveTest` (whisper routing + rename safety), with
  `Polyphony.SceneReset` / `mix scene.reset` for the clean-slate data wipe. Detail in
  `completed-roadmap.md`; phase 5 (open `name` to editing/arc override) stays in the backlog.
- **Adopt a LiveView storybook so components can be reviewed in isolation.** ✅ **Done** —
  `phoenix_storybook` at `/storybook`, one page per kit component with its states. Gated by
  the `:storybook` config flag (on in dev and test, elsewhere via `STORYBOOK=true`); it
  reads no domain data. The suite renders every story and fails if a kit component has no
  page, so the catalogue can't fall behind the components. Detail in
  `completed-roadmap.md`.

---

## Deferred (FS §18) — build the seam, not the feature

- **Onboarding** — a tutorial campaign + info-buttons on authoring surfaces. Seam:
  empty states (real calls to action) + the mandatory username step.
- **Subscriptions & notifications** — subscribe to a user/campaign. Seam: the
  notification-prefs surface (B4) + the public-profile page.
- **Payments** — undecided model (flat rate + optional pass-through). Seam: per-user
  spend accounting (B5); spend caps generalize into plan limits.
- **Bring-your-own endpoint** — per-user OpenAI-compatible URL. Seam: provider +
  base URL + key fields already exist; make them per-user + meter hosted vs BYO.
- **Collaborators / multiplayer** — shared campaign ownership; a second human on a
  character. Seam: V1.7 control-assignment *is* the multiplayer seam (a
  user-controlled character is what a second player occupies), and the
  viewer-parameterized stream already supports a second non-omniscient viewer;
  needs the A1 multiple-yields-per-beat work.
- **Public profile page** — creator-first surface; fields collected in B2.

---

## Suggested sequencing

1. **§A** — A1 (+ turn-order, next) → A2 → A3 → A5. Amendments to shipped behavior.
2. **B2 + B1** — auth/identity/roles/invites, then ownership/visibility/publish;
   build **§C** enforcement points alongside.
3. **B3** — admin/moderation, before enabling public browsing.
4. **B5–B9** — additive, by priority; B7 is cheap and high-value.
5. **B4 / B6** — notifications path + export.
6. **Frontend (LiveView)** — ✅ layered on the per-viewer broadcaster seam.
7. **Deployment** — ✅ OTP release + Dockerfile + DO App Platform, persistent event
   store (`docs/deployment.md`).

---

## Beyond v1

The post-v1 horizon — monetization shape, TTRPG resolution, kids/org products, style material,
and the ordering logic behind it all — lived here as "Part II" and now has its own home:
**`decisions.md`**. That's the *forward rationale*; this file stays the near-term *schedule*.
The concrete engineering worklist the schedule draws from is **`backend-backlog.md`**. See
`docs/README.md` for how the docs divide up.
