# Polyphony — Completed Roadmap

Shipped work, moved here out of the active planning docs so those stay lean. When a
`backend-backlog.md` item (or a `roadmap.md`/`decisions.md` line) is done, its detail
lands here and the source file keeps at most a one-line pointer.

**What counts as done here.** Backend work whose code + tests have shipped. An item with
a *frontend* remainder (the backend seam is built but no UI calls it yet) still lands here
for the backend half — the UI work is tracked with the frontend redesign, not as an open
backend task. Read newest batch first.

---

## The shipped roadmap — §A, §B1–B9, §C, and the parity audit

Moved here from `roadmap.md`, which had grown to five hundred lines of which four hundred
described work that was already finished. A schedule you have to read past the done items
to find the open ones is a schedule nobody reads; the near-term file now carries the open
work and a pointer for everything below.

Nothing here is edited — the text is as it stood when each item shipped. In order: the
build-order summary, the five §A amendments, §B1–B9, §C, the session's planned additions,
the one-pass FE/BE parity audit, and the first-cut LiveView's view inventory.

### Build order (§15), slices 1–9 plus branching

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

### §A — Amendments (revise shipped behavior)

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
- **A5 — Three nested content layers.** ✅ **Done.** `PolyphonyCore.Content` governs three
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

### §B — Additions (net-new surfaces)

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
    invites are single-use, and the first user bypasses. `reusable: true` mints one that
    stays valid after use — for putting a second and third account on a build by hand —
    and `revoke_invite/3` closes either kind, since an invite that never spends itself is
    a standing hole in the gate. Free / subscription tiers remain a future addition.
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
  - **One-beat Continue vs. Auto (✅ done).** A user Continue advances **exactly one beat**:
    its `control_hint: "yield_to_user"` is honored as authoritative over the model's own
    `control` (`RunBeat.cap_to_one_beat/2`), so the loop can't self-chain a string of
    autonomous beats per click (membership truncation still runs — that re-decides the same
    exchange, capped by depth, not `control`). **Auto** (`Polyphony.Director.Auto`) is the
    same loop without the hand-back: `control_hint: "auto"` forces `control: :continue`,
    the depth cap becomes the beat cap (50), and every slot is played — a user-controlled
    or assisted one would otherwise stall an unattended run at the first such character.
    It stops on the Director's `scene_action: :close`, on an empty room, or at the cap, and
    is pausable: a `scene_auto_runs` row rather than job args, because a pause is a fact
    about the scene and the play screen reads it on mount. *Not covered:* a location
    change, because `location_id` is fixed at `SceneOpened` and no event moves it — a
    Director relocating people is a `:move`, which exits them, and the empty-room rule
    catches that. A genuine mid-scene relocation needs an event first.
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

### §C — Cross-cutting data-handling ✅ **Done (backend)**

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

### Planned additions (this session)

1. **User-stipulated turn order + character removal per beat** → folded into **A1**
   (explicit turn-order event; re-roll reads declared order).
2. **CLAUDE.md / architecture.md / this roadmap** → ✅ done.
3. **DigitalOcean App Platform deploy + setup doc** → ✅ done. OTP release +
   Dockerfile, `.do/app.yaml` (PRE_DEPLOY migrate job + web service), persistent event
   store in a dedicated `eventstore` schema on the managed Postgres, DeepInfra via
   `DEEPINFRA_API_KEY`/model routing. See `docs/deployment.md`.
4. **First-user auto-admin + `superadmin` role** → folded into **B2/B3**.
5. **Invite-only sign-up (single-use links)** → folded into **B2**.

### FE/BE parity audit ✅ **Run once — findings below**

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
| **User-controlled turns** (§A1) | ✅ `submit_user_turn` / `pass_turn` | ✅ **now built** | — was: "I write their turns" had no interactive effect and double-turned |
| **Group arc fan-out** (§3.0b) | ✅ `GroupArc.fan_out/3` | ✅ **now built** | — was: no group editor at all, so the collapsed card could never populate |
| **Edit with tail invalidation** (§1.2) | ✅ `Edit.edit/6` | ✅ **now built** | — was: every edit was silently `:valid`, leaving turns written on top of a line that had changed |
| **Fork / branch from beat N** (§1.1) | ✅ `Fork.fork/3` | ⚠️ reachable via an invalidating edit, which is now wired | a scene branches when an edit changes what happened; there is still no bare "branch from here" |
| **Draft editing before accepting** | ✅ `Drafts.edit/3` | ✅ **now built** | — was: take it whole or throw it away |
| **Scene location as an authored field** (§2.3) | ✅ `OpenScene` takes `location:` | ✅ **now built** | — was: every scene opened nowhere |
| **Notification preferences** (§B4) | ✅ `Notifications.Prefs` | ✅ **now built** | — was: opt-outs existed and were unreachable |
| **Export / download** (§B6) | ❌ | ❌ | not started either side — no gap, just absent |
| **Failed turns requeue to tail** (§1.4) | ❌ deferred by decision | — | a failed turn is retried in place |

**Group arc was the one that wasn't a wiring job**, and it is now done.
`PolyphonyWeb.GroupEditorLive` (§06b) is the missing half: a group is written like a
character — the same prose blocks, the same secret control on its facts — with a Groups
card beside Cast to make one. Telling the members is deliberately *not* what saving
does: it is its own action, because seeding is a copy and members are separate people,
and `1 + n` reviewable proposals is what makes refusing one of them a story beat.

Two documentation defects found in the same pass, both since corrected: `Polyphony.Groups`
claimed the audience picker and group fan-out were unbuilt (the picker shipped; `fan_out/3`
exists and is merely uncalled), and `backend-backlog.md` §1.5 still said the approve card
was deferred after it was built. **A moduledoc that under-claims is how a shipped feature
gets built twice**, so these are worth the same care as the code.

The standing rule this pass exists to enforce: a new event type, context function, or
`Costs`/retrieval/generation seam is not done when its test passes — it is done when
something on the live path calls it.

**Interactive user-controlled turns — ✅ wired.** `PlayLive` keeps the beat that
`announce_progress` carries (it used to drop it), and the composer routes on it: with the
walk paused on the speaker's slot, Send is `submit_user_turn/5` against *that* beat and a
Pass control appears beside the field; with nothing waiting it is the free `CommitPacket`
at `next_beat` it always was. The banner is explicit, because otherwise the only
difference between "your slot is waiting" and "you are speaking out of turn" was which one
produced a double turn later. This is the path to "I play my character, the AI plays the
rest" and to multiplayer.

### Frontend (LiveView) — FS view inventory (the first cut)

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

### Two more of the frontend-rebuild foundations

Moved out of `roadmap.md`'s "Frontend redesign & design-kit fidelity" with the rest of the
finished work, so that section is the screens and nothing else.

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

## Frontend rebuild — the design-kit foundation

The first slice of the frontend rebuild (`roadmap.md`, "Frontend redesign & design-kit
fidelity"). It builds the machinery every ported screen uses; the screens themselves are
still open.

### The kit is derived from `ux/`, not copied from it
CLAUDE.md's convention was that `ux/polyphony-kit.css` is the single source of truth and
screens port from it — but a convention alone drifts. `mix kit.port` now *derives*
`assets/css/kit.css` from the design file by a mechanical transform, and
`PolyphonyWeb.KitPortTest` fails the build if the two disagree. Changing the design means
changing `ux/`, re-running the task, and committing both; there's nothing to hand-maintain
on the app side.

The transform makes exactly one change, documented in `Mix.Tasks.Kit.Port`: it drops the
kit's §11 mock chrome (wall labels around the mock frames — the kit itself says to strip it,
and its bare `body`/`h2` rules would leak into every page). Everything above that is copied
byte for byte, comments included, and `KitPortTest` asserts exactly that. The app's
stylesheet *is* the design's; a class means the same thing in both.

`app.css` is an ordered manifest — Tailwind, then the kit — and the order is load-bearing:
the kit is last so it outranks a utility it overlaps with, the precedence the mocks have.

Two compatibility layers were built and then removed, both on the same author call — that
the app has no users until the rebuild lands, so nothing should be designed around unported
screens continuing to work. First the kit was scoped to a `.fr` root so it could coexist
with the first-cut design system; that bought compatibility nobody needed at the cost of a
stylesheet that no longer matched the design. Then the first-cut system itself was
**deleted**. Screens that haven't been ported now render unstyled, which is the honest
state of a rebuild in progress. Their LiveViews and tests are kept — they're the record of
how each screen drives the domain, and the specification the replacement has to satisfy —
and each goes when its replacement lands.

### The kit's markup is `PolyphonyWeb.Kit`
The other half of the port: the kit's structural idioms as function components, lifted from
`ux/polyphony-kit.html` and the screen mocks — the perspective control, status strip,
transcript moves, marked list items, the info affordance, the nav primitives, and the
controls they sit in. Its one-class utilities (`.ttl`, `.mono`, `.dim`, `.lbl`) deliberately
stay as classes in markup, exactly as the mocks write them.

`PolyphonyWeb.Voice` holds the rule that makes voice colours useful: the same character is
the same hue in the transcript, the status strip, the cast list, the picker and their own
sheet, wrapping past eight, and emitted as `var(--vN)` so it resolves against whichever
register and theme the frame is in.

The hue is a **stored field on the character sheet**, minted once at `Library.put/2` — the
single door every character comes through — as next-in-rotation for that owner, so a fresh
cast spreads across the palette. It was first derived from position in a cast, which
satisfies the rule only until somebody is removed: then everyone after them changes colour,
including in transcripts they already appear in, which is the one place a colour is meant to
be a stable identity cue. Storing it also leaves room for an author to pick their own, and
an explicitly-set hue is never overwritten. `Scene.Cast` carries hues alongside names, from
the same sheet read, so a rename or a cast change can't move one.

### The catalogue: `phoenix_storybook` at `/storybook`
One page per component, with its states and the design's reasoning. Gated by the
`:storybook` config flag — on in dev and test, elsewhere via `STORYBOOK=true` — and it
reads no domain data, so it needs neither database nor LLM.

`PolyphonyWeb.StorybookTest` renders every story (a broken story is otherwise invisible,
since nothing else references the catalogue) and asserts **every kit component has a page**,
so the catalogue can't fall behind the components it documents.

Assets: the storybook loads its own bundle rather than `app.css`, so
`assets/css/storybook.css` is its own manifest — utilities, then the kit. It deliberately
leaves Tailwind's preflight out (a global element reset would restyle the storybook's own
chrome, which ships its own `psb-`-prefixed CSS) along with the first-cut design system (a
component that only looks right next to legacy CSS isn't ported yet). Both storybook bundles
are committed and covered by CI's asset-drift guard, like `app.{js,css}`.

### Character identity: the mint flip (`backend-backlog.md` §5.2, phases 2b-emit + 3 + 4)
The frontend rebuild carried this as a scoped requirement, and it landed with the id-native
play view. Before it, `character_id` in the event log was a character's **display name**,
keyed on with string equality through membership, packet ids, arc, and — the one that
mattered most — a whisper's `addressed_to`. Renaming a character already in scenes silently
corrupted them.

Now the log stores the character's **library id** everywhere, and names are display only,
resolved at the edges by `Polyphony.Scene.Cast`:

- **In:** `Cast.resolve_addressees/2` runs at every packet-production point immediately
  before `CommitPacket` — generation, the composer, an edit, an accepted draft, a
  user-controlled slot — so a whisper the model or the player wrote by name enters the log
  addressed by id. The Director's cast picks resolve the same way before
  `declare_turn_order`.
- **Out:** the prompt boundary already rendered names (phase 2b-render); the play view now
  does too — transcript, roster labels, composer, progress lines, failure lines, and the
  turn editor, which shows "(whisper to Bram: …)" and resolves it back on save.
- **Mint:** `EnterCharacter{character_id: <library id>}` at both sites — campaign
  scene-open and play's admit.
- **Arc + gate by id** (phase 4): `arc_entries.subject_id` is the library id, so arc review
  and `SceneGate` dropped the name-resolution dance they needed when the two identities
  disagreed.

`PlayIdentityLiveTest` is the guard, and it's shaped around the failure mode: an id/name
mismatch fails *safe* under default-deny (the whisper reaches nobody), so the tests assert
the addressee still **sees** the whisper after a rename as hard as they assert the bystander
doesn't.

**Data was cleared, not migrated.** Events are immutable (rule 6), so there is no in-place
rewrite of `character_id`, and a half-keyed scene is worse than either scheme.
`Polyphony.SceneReset` (`mix scene.reset`, or `bin/polyphony eval` in prod) drops every
stream and scene-derived read model and clears campaign `scenes` lists, **keeping the
library** — characters, worlds and campaigns are authored work.

Phase 5 (open `name` and other non-boundary scalars to editing and arc override, now that
identity is stable) stays open in the backlog.

### The app shell
Ported before the remaining screens, since every one of them sits inside it — and since the
play view was already fighting it (a viewport-height layout under a sticky top bar).

The design has **no persistent global chrome**, which is the finding that shaped this: every
mock is a full-bleed frame with its own header, and the only navigation drawn is a back
chevron for a drill-down and a `⋯` overflow on the right. So the sticky top bar with its
brand, links and hamburger is gone with the first-cut system it belonged to, and three kit
components replace it:

- **`Kit.header/1`** — the kit's own "standard header" spec (`polyphony-kit.html` §05):
  context small, title, controls top right, overflow last. Every screen with a title uses
  this markup, which is what makes moving between them feel like one product.
- **`Kit.menu/1`** — the overflow. Built on `<details>` so it opens without JavaScript and
  closes on Escape; a menu holding the sign-out link shouldn't need a live connection. The
  kit draws the closed pill but not the open panel, so that's its own sheet-and-rows rather
  than a new idea. Contents come from `Layouts.nav_menu/1`, so the set of destinations is
  defined once.
- **`Kit.toast/1`** — the flash, as the kit draws it: a dot in one of the three semantics and
  the action that produced it, with an undo slot for anything reversible. Flashes float over
  the screen in a pointer-events-none region, because a screen that owns the viewport can't
  have a banner pushing its bottom bar off.

`<body>` carries the register (`fr stage dark`). That's what gives the document a backdrop
and working tokens outside any screen's frame — without it the kit's colours resolve to
nothing and every page renders on browser-default white — and a screen still nests its own
frame to change register, as play does for a character viewer.

### Groups (the prerequisite the backend-asks pass missed)
The campaign port stopped at the Groups tab because nothing was behind it — and that's the
interesting part. `backend-backlog.md` had §3.0b, *group arc and how it reaches members*, which
reads as though groups exist; the pass recorded the sophisticated follow-on and not the artifact
it depends on. Building the frontend is what surfaced it.

`Polyphony.Groups` + `Polyphony.Authoring.Group` cover the artifact the design describes: *a
group is written like a character and used as a starting point for others — a crew, a household,
an order. It saves writing the same person five times, and gives secrets somewhere to point.*

- **Character-shaped, stored as a library entry** (kind `"group"`), so ownership, visibility,
  archiving and versioning come for free. It carries the fields that seed a person and not the
  ones that only make sense for a person — no relationships, no boundaries, no arc of its own.
- **Seeding is a copy.** `write_character/4` seeds a new character from the group's fields and
  facts — including its secrets, since knowing them is what belonging means — and joins them.
  Anything the author already wrote wins; the group is a starting point. Editing the template
  afterwards reaches nobody already written from it, which is what makes group arc a fan-out
  through review (§3.0b) rather than a silent propagation.
- **Membership is live, stored on the group**, ordered, keyed by stable library id (§5.2), with a
  character's groups *derived* so the two directions can't disagree. That's what an audience
  naming a group has to resolve against: the design's rule is that groups are named, not
  expanded — the membership moves.
- **Joining doesn't backfill.** `add_member/3` adds membership and nothing else. If Wren joins
  the Tidewatch in scene 9 she doesn't silently gain its secrets — she learns them in a scene.
  The reveal is fiction, not a migration, the same principle as world-arc catch-up, and it's the
  one a helpful implementation would quietly break. Pinned by a test.

Still open, and now recorded on §3.0b: the arc fan-out itself, and an **audience that names a
group** — `Fact` has `concealed: true` but no audience field, so nothing yet points at one. That
second one is what the audience-picker mock depends on, and why its inherited-tick treatment
can't be built yet.

### The campaign screen, ported (`ux/polyphony-campaign.html`)
The hub, and the screen the design pass changed most: one long scroll of every setting
became **tabs** — Settings · World · Cast · Premise · Scenes — because almost none of it is
needed at once. The tab lives in the URL, so a section is linkable and back works between
them.

Two of the mock's decisions are load-bearing and both are argued in `ux/README.md`. **Quick
Build isn't a tab**: it's a one-shot that would be dead weight from a campaign's second day,
so it's a first-run card that folds away. And **Premise comes after Cast**, because the
pitch is written *from* the cast — which is also what its Expand reads.

**Groups is not built.** The mock has the tab; the backend has no group feature (§3.0b is
still a backlog item), and a tab that leads nowhere is worse than an absent one. It goes in
with groups.

Two bugs came out of the port:

- **Partial saves wiped fields.** `update_details` wrote `params["name"] || ""` and
  `params["premise"] || ""` on every change. With one form that was survivable; with a form
  per tab it would have blanked the campaign name every time the premise changed. It now
  merges only the keys a form actually submitted, and the tuning block is only rewritten
  when its own fields are present (detected on a number input, since an unchecked checkbox
  submits nothing). Pinned by a test that edits the two on different tabs.
- **The cast was ordered by the library query**, not by the campaign's own
  `character_ids`, so the order shown depended on when characters were created. (This first
  surfaced as a voice-colour problem — colours were still order-derived then — which is what
  prompted moving the hue onto the sheet; the ordering fix stands on its own.)

### The play screen, ported (`ux/polyphony-play.html`)
The first screen rebuilt on the kit, and the one the design's two registers exist for.

**The register follows the viewer.** A character viewer gets `.page` — reading: wide
measure, 17px prose, the attribution as small caps in their voice colour, demeanor folded
into the prose, machinery at the edges. The omniscient author gets `.stage` — working: a
voice-coloured left inset per turn, gutter labels (Demeanor / Action / Speech / Whisper),
the control-mode pill, and the pencil-coloured editorial row (Reroll / Edit / Delete). Same
components, same tokens, different density.

**The author has no composer.** To write a character you become them, which is what the
perspective control is for; the GM's bar directs instead — Narrate, Cast, Introductions,
Continue. **Narrate is newly wired**: it dispatches `RecordWorldEvent`, the same event the
Director emits, so a human-authored world beat is visible to every member and reads as
fiction rather than as a note to the author.

**The status strip** (`PolyphonyWeb.Play.Strip`) is derived, never stored — the beat
aggregate already records who took their turn, passed or failed, and the declared turn order
says who is still to come. Its sentence answers "when do I act" without making anyone count.

It shows **every member of the beat to every viewer**. A per-viewer filter was built first,
reasoning by analogy with the transcript, and removed: presence is binary and symmetric
today (`Membership` is an interval, `visible_to?/3` judges it at the beat), so nothing can be
in a scene but unknown, and filtering would model a distinction the domain doesn't have —
while costing a player the thing the strip is for, which is telling a moving beat from a hung
one. That was a partial build of `backend-backlog.md` §2.2, which was already deferred
pending §2.1. Both are now specced to land together with the **context-generation** half,
since a concealed character reaching a prompt is the version of the leak that matters.

Two smaller corrections fell out of the port. A turn is now attributed **once**, at the head
of its block, so a move no longer repeats the actor's name — which retires the old
does-it-already-start-with-the-name guess that existed to prevent "Todd Todd". And the beat
rule is computed in one pass over the sorted transcript rather than each block guessing
whether it came first, which was drawing the same rule several times.

Connection state is rendered from the classes LiveView already puts on the container
(`phx-loading` / `phx-error`), so it needs no server state — and because reconnecting
replays the canonical scene, the copy can promise recovery. Silent when healthy: a permanent
"everything is fine" light is noise.

### What the character sheet needed first (`backend-backlog.md` §2.5, §2.12, §2.14)
Groups taught the lesson; this was applying it. Before porting a screen, check what it reads —
and the character sheet mock reads four things the backend didn't have. Built together rather
than one at a time, so the port doesn't have to come back for them.

**Cast tiers (§2.5).** `tier` on `CharacterSheet` — `:main | :recurring | :incidental` — and
deliberately a *second* axis from `status`. The two came apart the moment the design settled that
**no character ever plays without a full sheet**: if the walk-on the Director admits gets a
generated sheet like everyone else, `status` can no longer tell the bellman from the lead.
`Polyphony.Characters` holds the operations, with `promote/2` and `demote/2` symmetric on purpose
— the design's point is that a character who has served their purpose is *demoted rather than
deleted*, and a demote that quietly failed would push authors back to deleting someone the
transcript still refers to. What tiers do *not* do yet is decide context residency: the Director's
roster is a scene's own cast, not a campaign-wide one, so nothing has to choose who stays in the
room when they aren't in it. That question arrives with autogeneration-on-admit.

**The cover, and the one place the guarantee inverts (§2.12).** `cover` on `CharacterSheet` and
`WorldBible`, written by `Authoring.Cover`. Everywhere else the engine keeps a secret by never
putting it in the prompt — a character is not *told* what they can't know, so they cannot leak it,
which is why dramatic irony is structural rather than instructed. The cover is the exception: the
secrets are the input, because they're what makes a blurb feel like it's about something, and the
constraint lives in the prompt.

A prompt-level obligation earns a mechanical backstop. `Cover.generate/2` checks the returned
prose against the secrets it showed the model, retries once with a sharper instruction, and
returns `{:error, :leaked}` rather than a spoiler cover — a missing cover is recoverable, a
published one that gives away the twist is not. The check catches verbatim quotation only (a whole
statement, or a run of six consecutive words), which is the failure a model actually has with a
secret sitting in its context. `CoverTest` asserts that paraphrase gets through, on purpose: the
floor should not be mistaken for a ceiling.

**Sheet time travel (§2.14).** `Effective.sheet_as_of/4` folds only the arc extracted at or before
a stop; `Effective.scene_stops/2` gives the stops. A stop is a *closed* scene — a summary row is
written at scene close and only then, so its existence is what "closed" means, and it's the right
resolution because arc is extracted at close and there is nothing to wind back to between two of
them. The edges are where the thinking went: hand-authored canon has no source scene and so applies
at every stop, or the newest stop would disagree with `sheet/3` and the scrubber's right-hand end
wouldn't be the sheet you have; arc from a still-open scene belongs after every stop; and an
unrecognised scene degrades toward *less* arc, because this backs a read-only preview (§3.2) where
showing more than was asked for is a spoiler and showing less is merely stale.

**"In 3 scenes" (§2.14, the header line).** `Membership.scenes_for_character/2` and `scene_count/2`
— distinct scenes in first-entry order. Distinct because re-entry opens a second interval, and
someone who steps out and comes back is in one scene: the header must not count the door twice.

### The gap the four didn't catch: two directions of pressure (§2.16)
Reading the mock **section by section against the domain**, rather than against the backlog,
turned up a fifth. §05 asks for two lists — *what she won't do* and *what she can't stop doing* —
and `Boundary` modelled only the first. The lesson from groups again, one level finer: a backlog is
a summary of one reading of the mocks, so re-read the mock before porting the screen, not the
backlog.

The fix is `direction` on `Boundary` plus `after_release` (the mock's *and then* / *and now*,
written at authoring time but withheld from the character until the gate releases). What made it
worth doing before the port rather than after is what it exposed in `PolyphonyCore.Content`: capping
meant forcing `stance: :closed`, which for a compulsion means *she always does it*, so the content
ceiling would have compelled the content it exists to forbid. The cap now flips direction too — the
design's own rule is that the ceiling always pushes toward refusal, *because that's the correct
direction to fail in*.

### The character sheet, ported (`ux/polyphony-character.html`)
The longest form in the product, and the one whose layout argument is the strongest: **a sheet is
read, not just filled in.** No tabs and no accordions — you come back to it to remember who someone
is, which means reading top to bottom — so a sticky `Kit.jump` handles the length instead, giving
position without hiding anything. Prose first, structure after. Nothing on screen says *core* or
*status*: the model's vocabulary isn't the author's, and *Always in mind* actually explains the
behaviour it controls.

Everything is edited in place. There is no read mode and edit mode, because they'd be the same
screen twice.

**Facts got the treatment the design argued hardest for.** `core` and `concealed` are orthogonal
and are not collapsed: always-in-mind is whether *she* carries it, secret is who *else* has it, and
a woman can have a secret she never thinks about. Only one can own the left border, so secret takes
the structure and always-in-mind is a chip — which is exactly what lets a fact be both. State shows
in the row; the two switches live behind the row's `⋯`, because the list is read far more often
than it's edited.

**One structural decision the port forced.** The sheet is one form — cover, five prose fields, name
and pronouns — and a form inside a form isn't a thing, so the lists can't carry inline add-forms.
The mock had already solved it: adding someone is its own sheet (§04). So each list's *Add …* row
opens a panel below the sheet, outside the form. The constraint and the design agreed, which is
usually the sign the design was right.

`Kit.header` gained one attribute, `back_confirm`: the chevron is the way out of a drill-down, so on
an editing screen it's also the way out of unsaved work. Nil unless there's something to lose, so a
clean screen never prompts.

Also landed with the screen: `Autofill.suggest_facts/2` (the mock's ✦ Suggest on facts, with the
drawer's *a few is right* nudge written into the prompt), and the Mock returning all four flag
combinations so the offline path exercises the composition the list is built around.

### The world bible, ported (`ux/polyphony-world.html`)
The audit-before-porting routine paid for itself here: reading the mock against the domain found
a **prompt leak sitting one UI control away from being reachable**.

`WorldBible.rules` and `starting_canon` were plain strings, and `Context.render_bible` put all of
`starting_canon` into every character's prefix. §04 asks for one secret control in three places —
a rule, a canon entry, a character's fact — so the moment the screen let an author mark a world
fact secret, it would have gone straight into the model's context. That is the one place a leak is
invisible: the only symptom is a character who mysteriously knows something.

Both lists are now `WorldBible.Entry`, and the split is structural in the same shape `Visibility`
draws for events. A character reads `public/1`. The Director reads `statements/1`, because knowing
a secret is how it aims a scene at one. And anything that *writes* a character — a stub, a
generated sheet, a campaign premise — is character-facing too, since being written from a secret
is how a character comes to know it. Concealment is deliberately not world-arc reach: `scope` is
where a fact landed, `concealed` is who knows it.

**The screen.** Same long-form shape as the character sheet, because it's the same problem and the
design uses one navigation primitive for both. What's new is that it stopped treating its two kinds
of field as one: setting and tone are prose with Rewrite and Expand; rules and what's-already-true
are **items** with their own menu — secret, move up, delete. The old editor made both stacks of
textareas, which is exactly why reordering and the secret control had nowhere to live.

**The preview renders through the same filter the context path uses** (`WorldBible.for_character/1`),
not a second implementation of "what a character sees" — that's how a preview ends up telling you
something reassuring that isn't true. It's read-only per §3.2, and it says how much is held back
without saying what. There's no per-character list yet, and there shouldn't be: without audiences
(§3.3) everyone outside a secret sees the same thing, which is precisely the mock's own last picker
row — *somebody with no part in this*.

**The cover says what it was checked against.** "Checked against your 2 secrets" rather than a bare
claim of safety, because the claim is worth nothing without the count.

**A library world is a template** (§2.5b, shipped with this). Attaching copies it, so the editor
states which side of that it's on: a template says how many campaigns were started from it and that
edits reach none of them; a copy says it has a history and offers the one deliberate route back.

Smaller pieces the mock asked for and got: a duplicate world name refused at the field rather than
saved (§03), the share link appearing the moment unlisted is picked rather than minted and shown to
nobody, `New link` breaking the old one, and the write-it-from-a-line card leading an empty world
and folding away once there's something there — the same argument as the campaign's Quick Build.

### The audience picker (`ux/polyphony-audience-picker.html`, `backend-backlog.md` §3.3)
Not a screen — a component, on two surfaces already ported. Which made the audit's question
sharper than usual: §3.3 was deliberately scheduled *later*, so was this the screen where the
honest answer is "not yet"?

It wasn't, and the reason is the thing that had changed underneath it. Groups exist. Secrets now
exist in three places. And §3.3's own argument is that unscoped audiences — *everyone* and a named
set — make **secret shorthand for an audience narrower than everyone**, one mechanism rather than
two. Everything the ask says is hard is the *scoped* half (locations, "whoever was there"), and
none of it blocks the rest.

**The shape avoids the matrix.** Authored from the secret's side, so it scales with the number of
secrets rather than secrets × cast. "Everyone" is deliberately not a stored value — it is the
item's `concealed: false` state, because two representations of one idea is how they drift apart,
which is the exact failure this component exists to prevent. Additive only: an inherited tick
can't be individually removed, and the picker says so rather than hiding it.

**Groups are named, not expanded** — the load-bearing decision. Resolution reads current
membership at the moment the question is asked, so a walk-on written into the Tidewatch in scene 9
arrives already knowing and nobody assigns anything. The picker's footer says who that means
*right now* for the same reason: a count frozen at authoring time quietly becomes a lie.

**And it reaches the prompt.** That's the only thing that made it worth building now rather than
later, and it's the rule this project already set for itself when presence filtering came up —
handle it in the interface *and* in context generation at the same time, not partially.
`Context.materialize` takes the campaign's cast and tells a character the secrets their audience
puts them in on, rendered into the same "You know:" block §6.1 already describes, so the prompt
shape doesn't change. `WorldBible.known_to/3` does the same for world entries. Absent a cast it is
default-deny — a caller that doesn't supply one makes a character know too little, never too much.

The character-side read-back (§04) is a **derived projection**, not a second store: you see it from
a sheet, you edit it from the secret, and each line says how they came by it so an inherited one is
obvious. One fact, one home.

Still open and recorded: *whoever was there* (it needs a source scene, and nothing carrying an
audience has one yet), audiences on arc entries, and location audiences — which the design checked
against the component and which need no change to it.

### Arc review, ported (`ux/polyphony-arc.html`)
The audit found four things the domain couldn't say, and the screen needed all four.

**Every proposal says why.** `reason` on both arc kinds, asked for by both extractors. The design's
argument is that the *Because* line is what makes accepting quick — you can check the reasoning
without going back and rereading — so a proposal that can't say why is one you have to earn twice.
A model that skips it still produces a usable proposal; dropping an entry over a missing
justification would be the worse trade.

**A line gave is its own kind.** `BoundaryGate` already resolves a conditional boundary
scene-locally from canon; a canon `:release` names the topic and opens it permanently. That is
exactly the distinction the design draws — the gate resolved it in play, review is where it stops
being scene-local — and it's why that card offers *Not yet* rather than *No*: the fiction isn't
being rejected, the line just hasn't given.

**World arc says who knows.** A character's arc is theirs; a world's is everyone's. Two answers
cover almost everything: *everyone* (common knowledge, and what fixes the off-screen problem — the
fact is simply present the next time they turn up) and *whoever was there*. The second is why the
`Audience` scene case could land here and couldn't on authored canon: arc is the one thing with a
source scene. It's expanded at fold time, unlike a group, and the difference is the point — a
scene's cast is finished history and can't change, so resolving it once is safe.

**Group arc fans out** (§3.0b): one proposal against the template, one per current member, each its
own yes or no. Nothing propagates silently — six members is six things to say yes or no to, not one
switch that rewrites six sheets. Which is what makes dissent free: refuse one member's and you've
written the person who didn't go along with it, a story beat you'd otherwise author by hand.
Off-screen members are included, and so is someone who joined by hand and was never seeded, because
membership is what matters. The screen collapses it to one card with one fast path, expandable when
it matters.

**The screen** is a tab per subject — reviewing is per-person work, and a flat list makes you
re-orient on every card. A tab with nothing pending still shows, at zero, so its absence never
reads as *not extracted yet*. A revision shows what it replaces, struck through, because a
replacement you can't compare is one you have to take on trust. Accept-all is per subject, which is
the scope the gate cares about.

Still open and recorded: the async extraction states (*still working it out*, *couldn't be worked
out — try again*) which need the job's status surfaced, the in-row review at scene setup (§04c), and
the edit split between correcting the base and adding a new change (§04). Triggers stay unbuilt —
the mock says so itself; the provenance slot is there so it needn't be retrofitted.

### The library, ported (`ux/polyphony-library.html`)
Not a create hub any more. The audit found four things the domain couldn't say, and one of them
was a promise with nothing behind it.

**A campaign says where it is** (§2.5c). `Polyphony.Campaigns` — `:unstarted | :playing |
:finished`, derived from the scenes list except for `finished_at`, which is the one thing the data
can't work out for itself. **Finishing is not archiving**, deliberately: archiving is filing and
says nothing about the story, while finishing is a statement, the precondition for another
campaign naming this one a prequel (§3.4), and reversible, because concluding something is a
judgement. `pending_review/2` counts a campaign's cast's proposals *and* its world's — the same
number the scene gate blocks on, so the row an author reads before opening a campaign is the
number that will stop them.

**The recovery window is a number, not a claim** (§2.13). `Library` had `soft_delete`, `restore`
and `purge`, and nothing that ever called the last one — so *deleted things wait 30 days* had
nothing behind it and the trash row's countdown would have counted down to a day that never came.
Now: a defined window, a `days_until_purge` that rounds **up** (a sliver of a day left never reads
as none) and bottoms out at zero, `purge_expired/1`, and `Jobs.PurgeTrash` on a nightly cron. The
job is the entry; the rest is display.

**A reading shelf** (§3.1e). `Polyphony.Reading` — scene, beat and **perspective** together,
because perspective is part of where you were and coming back into a different head is coming back
to a different story. A published campaign you're reading isn't a campaign you own: you can't play
it, you may not be able to fork it, and it can be unpublished out from under you. Filing it under
Campaigns would promise all three; its own shelf promises exactly one thing. Unpublishing keeps
the row and keeps the place — `:gone` is a state, not a deletion — because unpublishing is usually
temporary and losing someone's place isn't recoverable from their side.

**The screen** has one create button; worlds and characters are made inside a campaign, so the
three-way "what do I make first" question never gets asked, and first run says so with no taxonomy
lesson. People group by campaign for free (§2.7) with walk-ons collapsed behind a count, because
they're the tier you scan past. Worlds lists **templates only** — attaching copies (§2.5b), so
without that filter the tab shows the same name three times, two of which belong to campaigns —
and each row counts the campaigns that *started from* it, past tense. Archive and trash are two
shelves side by side, reachable from a tab and from the campaigns footer, which is the front door
they have never had.

Two things moved rather than being dropped: bulk stub generation is now on the campaign's cast,
where the pending characters actually live, and the library's per-entry visibility control is gone
because changing who can see something belongs next to the thing itself — the library wears the
badge, the editors own the control.

Still open and recorded: *Carry on reading* has nowhere good to go until the published reading
view (§3.1b) exists, so it falls back to the share link or browse; library-wide search stays
§2.15, deliberately later.

### Browse and the published reading view, ported (`ux/polyphony-browse.html`)
Publishing worked and produced nothing anyone could read. This is the missing half — and the
biggest backend ask in the rebuild, because a reading surface is not a list with prose in it.

**Publication names perspectives, not surfaces** (§3.1, §3.1c). `PolyphonyCore.Publication` asks two
separate questions rather than one ladder: *how it's meant to be read* — which perspectives a
reader may adopt, a content decision and the **spoiler control** — and *whether the authoring
surface is exposed*, which is one checkbox, `forkable`, and brings sheets with it because a fork
can't continue a story from prose alone. Enumerating surfaces instead would mean every new feature
ships a new toggle and the defaults rot; filtering by perspective covers surfaces that don't exist
yet. The grant travels **with the snapshot**, not on the live campaign, because the snapshot is
what readers hold and it must not change under someone partway through.

**Two new viewers, and neither loosens anything** (§3.1b). `{:readers, ids}` — *everyone the
author shared* — is a **union over the existing character predicate**, so it inherits default-deny
for free and cannot drift from what those characters actually knew; the union is bounded by the
grant, so it is never omniscient. `:spectator` is genuinely a different projection (nobody in the
fiction has it), so it's written as its own default-deny clause, with whispers denied *ahead* of
the general speech clause — the order of those two is the whole difference between a spectator
read and a leak. Settings a snapshot never had read as spectator-only: the least-granting answer.

**The gap can be the point; it just can't be an accident** (§3.1c-ii). If spectator is off and a
scene holds none of the published cast, nobody can open it. `Preflight` warns at publish time,
live as the grant changes, and never blocks. Unreadable scenes still appear in the contents,
marked — silently omitting one would make the numbering lie and the story jump. The perspective
selector on a scene is filtered to what can show it, with the reader's current perspective kept
**last rather than removed**, so the control never reorders under them.

**Root identity** (§3.1d). Every campaign copies its world and every fork copies everything, so a
`derived_from` parent pointer means walking the chain per row to group a list. `root_id` is
stamped at insert and carried forward by `copy/3`, so a fork of a fork groups under the thing it
all started from. Browse groups by it; `provenance/2` walks back to both parent and original.

**The screen** is the catalogue, a story's front page, the reader, and taking something with you.
Choosing how to read comes before reading — the first real decision, and putting it up front is
what stops the picker feeling like a settings menu. The reader is **the play screen with a
different bottom bar**, which is now literally true: `PolyphonyWeb.Transcript` was extracted from
`play_live` and both render through it, because a second implementation of prose rendering is how
the two drift and the one a reader sees is the one nobody is looking at. Two kinds of empty stay
distinct — *Halden wasn't here* has a way out, *this one isn't shared* doesn't. An action that
isn't available simply isn't shown: no greyed-out buttons and no "request access". Reading never
hits a wall for a signed-out visitor; only the actions do.

Taking the world out of a story is its own operation, because the bible is embedded rather than
referenced: `WorldBible.stripped/1` drops every concealed entry, so the setting travels and the
secrets don't. And the moderation queue, fully built and never reachable, finally has a way in —
reports target the frozen snapshot, so a take-down leaves the author's original alone.

Still open and recorded: the reading position resumes at the story rather than at the bookmarked
scene until the front page consults it, and the library's by-campaign version grouping (the other
half of §3.1d) isn't built.

### Settings and auth, ported (`ux/polyphony-settings-auth.html`)
Two things here were load-bearing, and the first had been a promise with nothing behind it.

**A cap you can actually change** (§B5). The error copy has said *you can raise it in Settings*
for a long time, and both ceilings lived in app config — identical for everyone, editable only by
a deploy. Now a cap resolves **stored → opts → config → default**: `users.daily_cap` is the
account's own number, a campaign's `spend_cap` is the story's, and a null means "the configured
default" rather than zero, so raising the default still reaches everyone who never touched theirs.
They protect against different things — a daily cap against a runaway loop, a lifetime one against
a single story eating the month — so they live in different places, and each *where it went* row
links to the campaign that owns its own.

Spend is shown as **turns remaining, not a percentage**, estimated from what this account's recent
generations actually cost: nobody knows what 86% of their budget feels like. It returns nil rather
than guessing with no history, because a made-up number here is worse than an absent one. And
per-campaign spend — which had never been shown anywhere, which is how one story eats a month
unnoticed — is a list, with authoring outside any scene as its own honest row.

**Leaving is a decision on a clock.** `deletion_requested_at` plus `Jobs.PurgeAccounts` on a
nightly cron; signing in cancels it, which is what makes *sign back in within 30 days and none of
this happens* a promise rather than a hope. A forked copy of a published story is **not** touched:
it's theirs now, and deleting someone else's work to honour this request would be the wrong trade.
The confirmation counts what goes rather than describing it, because "all your work" is easy to
skim past and "three campaigns, two worlds and forty-one characters" isn't.

**18+ is eligibility, not a content setting.** Unchecked ends the signup rather than limiting it,
and the screen it ends on has no retry and no way back — a door that reopens on the same screen
isn't a door. Two properties that were already right were pinned rather than changed: refusing
somebody creates **no row about them** (`register/2` checks attestation before it touches the
database) and **doesn't burn the invite**, so whoever sent it can pass it on.

Sign-in is magic-link only, so *check your email* is the whole experience: both escape routes and
the spam line before anyone needs it, and an unknown address gets the identical screen because an
enumeration oracle is a worse trade than a moment of ambiguity.

Still open and recorded: the mock's **signed-in-on device list** isn't built. Sessions are
cookie-only today, so it would mean a persisted session store — a change to auth transport rather
than a domain gap, and showing a device list backed by nothing would be worse than not showing one.

### Moderation, ported (`ux/polyphony-admin.html`)
The queue was fully built and had never had an input; that got fixed with browse. This is the
other end — an internal tool for people making judgement calls under time pressure, where density
is fine and ambiguity isn't. Four things it has to get right, and two of them needed new domain
behaviour rather than new reads.

**Child safety is its own lane.** `Moderation.lanes/1` — not a filter on a general queue but a
separate list that is always first and doesn't get buried under forty spam reports. Oldest first
within a lane, because the alternative is reports that never get looked at.

**A take-down spreads, and can't spread blind.** The public copy and the author's own, plus every
fork descended from it — but a fork may have diverged twenty scenes past anything objectionable,
so deleting the family is wrong and ignoring it is worse. `take_down/4` now hides the family
(via `root_id`, §3.1d) into a **review lane** where somebody looks, with *leave it* and *take it
down too* as the two outcomes. `hidden_at` is a fourth axis on a library entry, deliberately
separate from visibility, archiving and deletion: the owner's own `visibility` is untouched, so
lifting restores what they chose rather than what a moderator guessed.

**A suspension hides everything shared, unlisted included.** Otherwise a suspended person makes a
new account, opens their own share link, and forks their way back in — so `get_by_share_token/2`
and `list_public/2` both check `hidden_at`, at the query rather than at the call site.
`suspended_until` makes *7 days* / *30 days* / *until we say otherwise* real, and it's **read
rather than swept**: a lapsed suspension stops binding the moment it lapses, with no window in
which somebody stays locked out because a job hasn't run. Suspended accounts are signed out on
their next request.

**Reading a report means bypassing publication scope**, and the screen says so out loud rather
than granting it silently: a *why* field, stored in the audit metadata with the moderator's name.
A reason field turns an unlogged habit into a decision — nobody types one forty times a day for
something they don't need — and privilege use is tinted in the audit list, because it's the entry
most likely to matter later and the least likely to be looked for.

Content and people never share a row: different consequences, different reversals. And two things
that existed in the domain and had never been reachable now have buttons — **demotion** (an admin
promoted by mistake was permanent) and **reinstatement** (an indefinite suspension with no way back
is a deletion nobody agreed to). The first account stays pinned, since there is exactly one
superadmin and it is never assignable.

Also here: reports read **both directions**. Someone whose own reports are nearly all dismissed is
a signal too, and a queue that only ever looks at the accused can't see that.

---

## Immediate milestone — the backend the frontend design needs

The slice of `backend-backlog.md` that gated the shipped frontend design. All of it is
done except §1.4 (deferred by decision) and §2.8 (world arc, in progress separately).

### §5.1 — Scene-close fan-out is now triggered · *wiring*
`SceneClose.enqueue/2` had no caller, so per-character summaries and arc extraction never
ran in production — the whole memory/arc layer was dark. Wired by
`Polyphony.SceneClose.Handler`, a `start_from: :current` Commanded handler on `SceneClosed`
that calls `enqueue/2` (jobs resolve the configured provider/embedder at run time).
Supervised with the projectors and off in tests (its `Oban.insert!` touches Postgres);
`start_from: :current` so a deploy doesn't re-summarize every historically-closed scene.

### §1.1–1.3 — Branching family (fork / edit / lineage) · *found already complete*
No new code needed — the copy-on-fork design already satisfied these. A fork is a **new
scene stream** keeping `beat ≤ cut`, so it opens live at the cut beat and `Reroll`/`Edit`
read `latest_beat` off that stream (branch-relative for free); `Edit.edit/6` is fully built
(`:valid` any beat, `:invalid` forks); `ReadModels.SceneFork` records the cut beat and
nothing else. Remaining "Branch from beat N" UI is frontend, deferred.

### §1.5 / §1.6 — Draft accept/discard, pass-turn · *backend built*
`BeatDriver.accept_draft/2`, `discard_draft/2`, and `pass_turn/4` are complete and tested.
The affordances (approve/discard card, composer "pass" buttons) are frontend, deferred with
the redesign.

### §1.7 — Failures scoped per viewer · *change*
Turn (`packet`) failures now broadcast to the omniscient topic **and** the failed
character's own viewer topic (`Failures.broadcast/1`); author-facing failures (scene-close
summaries, arc extraction) stay omniscient-only. `Failures.list_open/2` gained a `subject:`
filter (`Failure.list_open_for_subject/3`, `packet` ops only); `PlayLive.open_failures` loads
per-viewer — GM sees all, a character viewer only their own turn failures. `Broadcast.viewer_tag/1`
made public. (Rests on the beat's carry-on behaviour, which already held — see §1.4 below.)

### §2.3 — Scene premise & location as authored fields · *backend done*
`SceneOpened`/`OpenScene`/the `Scene` aggregate already carried `premise` + `location_id`, and
premise already reached context. Added the missing half: `location` rides `SceneContext` and
renders in the **volatile** suffix (`"Location: …"`, distinct from the world bible's
`"Setting:"`) so it never enters the byte-stable prefix; `SceneBrief` renders it for the
Director; `Context.Rebuild` + the `SceneBrief` rebuild feed `opened.location_id` (proven
end-to-end by a rebuild test). New scene-aware `Autofill.generate_scene_premise/1`, grounded in
world + cast + setting + campaign premise + previous scenes. The "Set the scene" form and the
LiveView seed sites passing `location:` are frontend, deferred.

### §4b.1 / §4b.2 — Account framing · *change*
18+ reframed as **eligibility, not a content ceiling**: sign-up already rejected an unchecked
attestation before any write (no user row, invite not burned) — now pinned by a test; the
`Content.Floor` `attested` branch stays a latent under-18 seam. Removed the settings "opt out
of proactive analysis" control (there is no automated analysis to opt out of); the §C domain
seam stays latent for when the feature exists (per campaign, per the design).

### §2.8 — World arc · *new (A–D)*
Durable world change, mirroring the character-arc pipeline. Once per scene close,
`SceneClose.WorldArcExtractor` reads the **unfiltered** stream and proposes standing world
facts (discovery/revision), each tagged **global** or **local**; `ExtractWorldArc` fans out
one job per scene (`extract_world/2`), keyed to the campaign. Stored by reusing `arc_entries`
via `subject_type: "world"` + two columns (`scope`, `location_id`).

Consumption (the payoff): `EffectiveWorldBible.apply/3` folds canon world facts into
`starting_canon` in beat order — global everywhere, local only at its scene location, the
Director (`:all`) omniscient. `Authoring.Effective` centralizes "load canon + apply" and is
wired into both rebuild paths (`Context.Rebuild`, `SceneBrief`) and the live scene-open seeds
(`play_live`, `campaign_live`). **This also finally wired canon *character* arc into
generation** — `EffectiveSheet` was built but consumed only by publishing; both seams fixed
together. Review (`ArcReviewLive`) gained a world section plus **reject** and **edit** (wording
+ scope) beyond accept, backed by `ArcEntry.reject/2` / `edit/3`. Off-screen catch-up is by
fact-injection, never extrapolation — the character reacts on screen.

Left open, recorded in the backlog: arc extraction is unattributed (no metering, matching
character arc), and §3.0 gating sits on top and stays deferred.

### §3.0 — Arc review gates the next scene · *new (MVP)*
Opening a new scene now requires the cast has no pending character arc and the campaign no
pending world arc — an unreviewed proposal is a gap between the sheet generation reads and who
the character has become. `Authoring.SceneGate.check/3` evaluates **per selected cast** (not the
whole backlog), keyed by character **name** (the id scenes + extraction use); world arc blocks
campaign-wide. `campaign_live`'s start-scene consults the gate before `OpenScene` and redirects
to arc review on a block; it never affects closing a scene. Also fixed `ArcReviewLive` to resolve
cast library-ids → names (it was querying by id and showing nothing for real campaigns) and added
**accept-all**, the one-tap way through the gate. Refinements left open (recorded in the backlog):
the failed-extraction and not-ready-yet async states.

Also plugged two future features into `decisions.md`: **P13** a campaign companion Q&A agent
(ask-your-story, read skills over the log/sheets/arcs with the visibility lens), and **P14**
design-thread tooling (docs/ux access skills + the docs-in-repo-vs-hosted open question).

### §5.2 — Character identity migration: domain foundation · *change (partial)*
Character `character_id` in the event log was the display name, keyed on everywhere — so a rename
would silently corrupt references. Shipped the durable, safe **foundation** toward stable-id
identity: (1) `Rebuild.sheet_for` resolves a scene's `character_id` to its sheet by **library id
first**, then the legacy name match — rename-safe lookup; (2) `Scene.Cast` — a scene's id↔name
resolver (`render_name`, `resolve_id`) with identity fallback; (3) **id→name at the prompt
boundary** — `context` and `scene_brief` render display names from stored ids, so the LLM always
sees names. All legacy-tolerant (an unmapped id renders as itself), so the suite stayed green.
The **atomic mint-flip** (resolve emitted names→ids + enter characters by id + the `play_live`
overhaul + data clear) is **deferred to the frontend rebuild** to build the play view id-native
rather than overhaul-then-discard it — tracked in `backend-backlog.md §5.2` and the frontend
roadmap item. Also: metering fix (arc/world-arc extraction billed to the campaign owner; latent
`Costs.check` nil-user crash fixed).

---

## The shipped backend backlog — §1–§5

`backend-backlog.md` and `roadmap.md` are **retired**. The worklist they carried now lives
in Linear (team `StrutCo`, project `Polyphony`), where an item can be prioritised, moved
through Designing → Ready for dev → In Progress, and closed — none of which a markdown list
can do. Every open item became an issue; the argument in each one went with it.

What follows is the other half: the **shipped** sections of `backend-backlog.md`, verbatim,
because they are the record of what was built and why, and several are the citation target
for `§n` references in moduledocs and tests. Nothing here is a task.

Two notes on what didn't survive the move:

- **§2.10 auto-advance shipped** and the file never said so. `Polyphony.Director.Auto` is a
  full auto mode — it runs until the Director closes the scene, the room empties, or a
  50-beat cap, with pause/resume as a DB row checked at the top of every beat, and
  `control_hint: "auto"` forcing `control: :continue`. The backlog still described it as
  "new (surface) + wiring".
- **§6's "pronouns as a character field" contradicted §2.11**, which shipped pronouns. The
  §6 bullet was stale and was dropped rather than filed.

**§5.2 phase 5 is still open** — it is the one open item inside a section kept here, and it
is tracked as its own Linear issue (opening the non-boundary sheet fields to arc override).

### 1 · Blocking the current design

#### 1.1 Fork wiring — `Fork.fork/3` · ✅ **Shipped** (found already complete)
Fork truncates at the cut beat and opens live there; `Reroll`/`Edit` are branch-relative for
free because a fork is a separate stream. "Branch from beat N" UI is frontend, deferred. See
`completed-roadmap.md`.

#### 1.2 Edit with tail invalidation — `Edit.edit/6` `:invalid` · ✅ **Shipped** (found already built)
`Edit.edit/6` complete (`:valid` any beat, `:invalid` forks); no branch-relative guard needed.
Caller (frontend) deferred. See `completed-roadmap.md`.

#### 1.3 Lineage records the cut beat and nothing else — `ReadModels.SceneFork` · ✅ **Shipped**
`SceneFork` records `fork_beat` and nothing else, as prescribed. The optional read-time
"identical-so-far / changed" comparison is a small helper to add when the branch-navigator UI
wants it — not a blocker. See `completed-roadmap.md`.

#### 1.5 Draft accept / discard · ✅ **Shipped**
`BeatDriver.accept_draft/2` and `discard_draft/2` complete and tested. The approve/discard card
is built: `PlayLive` loads open drafts on every reload and renders each through the transcript's
own `render_move/4`, so what is approved reads as it will read committed. Drafts announce on
`Drafts.topic/1` — a workflow topic carrying no fiction — which is what lets a character's view
hear about one without subscribing to the omniscient projection. See `completed-roadmap.md`.

#### 1.6 Pass turn · ✅ **Shipped (backend)**
`BeatDriver.pass_turn/4` complete; the composer/quick-sheet entry points are frontend, deferred.
See `completed-roadmap.md`.

#### 1.7 Failures scoped per viewer · **change** — ✅ **Shipped**
Turn failures now reach the failed character's own viewer topic (+ omniscient); author-facing
failures stay omniscient-only; `PlayLive` loads per-viewer. See `completed-roadmap.md`.

---

### 2 · New — not modelled yet

#### 2.16 A character can be pushed in two directions · **change** — ✅ **Shipped**
`direction` on `CharacterSheet.Boundary` (`:refusal | :compulsion`, defaulting to refusal), plus
`after_release` — the mock's *and then* / *and now*, written when the line is created but withheld
from the character's context until the gate actually releases, so she can't play the aftermath
before earning it. `Autofill` proposes both directions; `Context` writes a compulsion as a
compulsion rather than as a negated refusal, because a model handed "you will not not do this"
writes a worse beat than one handed "you can't help it". `CompulsionTest` pins the axis.

The bug this closed is in `PolyphonyCore.Content`. Capping meant forcing `stance: :closed`, which for a
compulsion means *she always does it* — so the content ceiling would have **compelled** the content
it exists to forbid. The cap now flips direction as well as stance, per the design's own rule:
*the ceiling always pushes toward refusal. That's the correct direction to fail in.* Original ask
below, reconstructed from the mock.


`ux/polyphony-character.html` §05 asks for two lists, not one: **what she won't do** and **what she
can't stop doing**. `Boundary` modelled only the first. The design argues the split is the point —
*direction lives in the grouping, not the wording*, so an item can never be read backwards, which
is exactly what went wrong when everything was one list of "lines" — and that compulsions are the
more dramatic half: *covering for her father is a better story engine than any refusal on the
sheet.*

#### 2.17 Anything in a world can be marked secret · **change** — ✅ **Shipped**
`WorldBible.rules` and `starting_canon` are lists of `WorldBible.Entry` (statement +
`concealed`), which is the design's *one control, three places* (`ux/polyphony-world.html`
§04) reaching the world layer. A bare string still reads as a public entry, so stored
payloads and generated lines need no migration.

The reason it had to land with the screen is that it was a **prompt leak waiting for a
control**. `Context.render_bible` put all of `starting_canon` into every character's prefix,
so the moment the UI let an author mark a world fact secret it would have gone straight into
the model's context — the one place a leak is invisible and the only symptom is a character
who mysteriously knows something. The split is now structural, in the same shape `Visibility`
draws for events: a character reads `public/1`, the Director reads `statements/1`, and
anything that *writes* a character (a stub, a generated sheet, a campaign premise) is
character-facing too, because being written from a secret is how a character comes to know it.
Pinned by `WorldSecretsTest`.

Deliberately **not** the same axis as world-arc reach: `scope` answers *where a fact landed*,
`concealed` answers *who knows it*. Folding them together would make a local fact secret and a
global secret impossible. **Who else** knows one is still §3.3.

#### 2.3 Scene premise and location as authored fields · **new** — ✅ **Shipped (backend)**
Location now feeds Director + character context (volatile suffix, `"Location: …"`); new
scene-aware `Autofill.generate_scene_premise/1`. The "Set the scene" form + LiveView seed sites
passing `location:` are frontend, deferred. `location_id` stays a reference field so it can
become a location-entity FK later without changing the event shape. See `completed-roadmap.md`.

- Both are Director context. Today the Director infers the situation from the world bible and
  the transcript; this gives it the GM's actual intent for *this* scene.
- **Location is authored, not inferred.** The Director should not be deciding where a scene
  takes place. It also resolves a copy problem — with a location field the header can name
  the place rather than guess a preposition for it.
- **Premise wants an Expand call**, grounded in world + cast + previous scenes, matching
  `generate_campaign_premise` (§4). New call; the campaign one isn't scene-aware.

**Constraint worth flagging.** `Context.materialize` freezes a per-character prefix ordered
stable→volatile for prefix-cache hits (§6). Scene premise and location are scene-scoped and
change every scene — placed too early in that order, every new scene invalidates the cached
prefix for the entire cast. They belong at the volatile end, near the verbatim recent scenes.

Forward-compatible with later location authoring: the field should be able to become a
reference to a location entity without changing the event shape.

#### 2.5 Cast tiers — context residency, separate from sheet status · **new** — ✅ **Shipped (the axis)**
`tier` on `CharacterSheet` (`:main | :recurring | :incidental`), with `tiers/0`, `resident?/1` and
`tier_label/1`; `Polyphony.Characters` holds the operations — `set_tier/3`, symmetric `promote/2`
and `demote/2` that step one place and saturate at the ends, `by_tier/1` for the cast list's
sections, and `resident/1`. A walk-on written during play (`Authoring.Stub`) starts `:incidental`.
`CharactersTest` pins that the axis stays independent of `status` and that demotion works as well
as promotion — the design's point being that a character who has served their purpose is *demoted
rather than deleted*.

**Still open:** nothing *consumes* residency yet, because there is nothing to consume it from —
the Director's roster is a scene's own cast (`Context.Rebuild.roster/1`), not a campaign-wide one,
so no read currently has to choose who stays in the room when they aren't in it. That arrives with
the rest of this entry: **autogeneration-on-admit** and its timing constraint (the scene must not
block on the generation, but the character must). Original ask below.


Design principle this falls out of: **no character ever plays without a full sheet.** Admitting
a walk-on autogenerates one rather than admitting a stub — it's a real advantage of the
engine that the bellman can have a backstory nobody asked for, and it costs the GM nothing.

But that breaks the axis we currently have. `CharacterSheet.status` is `:stub | :proposed |
:full` (§4) — if everyone who plays is `:full`, status no longer distinguishes anything
useful, and the campaign's cast grows without bound while `Context.materialize` (§6) has no
basis for deciding who stays resident.

**Wanted: a second axis for context residency**, orthogonal to whether the sheet is written.
Roughly: **main cast** (always resident), **recurring** (resident — a major side character
who should remember and be remembered), **incidental** (loaded only for scenes they appear
in). Promotion and demotion between tiers needs to be a real operation, in both directions —
a walk-on who turns out to matter gets promoted; a character who's served their purpose gets
demoted rather than deleted.

This also gives the library and the cast list something to sort by, which they currently lack
once autogeneration starts filling the roster.

**Simplifies considerably once locations are authored** (2.3): an incidental character can be
tied to one or more locations, and the location tells the Director who belongs in context —
no manual tiering for the majority of them.

**Timing constraint.** Autogenerating on admit puts a full-sheet generation inside a one-tap
action during a live beat. **The scene must not block on it, but the character must.** They
enter immediately — membership is recorded, the room knows they're there, and the beat
proceeds around them — but they are not actionable until the sheet lands. In practice that
means the Director skips them for turn assignment while generation is in flight, and they
become castable on the next beat after it completes.

This matters because the alternative — letting them act from the proposal's one-line premise
— produces a character whose first turn contradicts the sheet written a moment later. Better
that they stand there for a beat.

Consequences: a character can be a scene member with a sheet in flight, so any read path that
assumes membership implies a full sheet needs to tolerate it. And if the generation fails,
they should stay in the scene as un-actionable with a retry, not be silently evicted —
eviction would be a membership event the room can see, for a reason that has nothing to do
with the fiction.

#### 2.11 Pronouns are a field · **change** — ✅ **Shipped**
`pronouns` on `CharacterSheet` (free text, never an enum — the set isn't closed), rendered into
the character's context immediately after their name because it governs every sentence written
about them, offered by `Autofill` with explicit guidance not to infer from the name, and
editable on the sheet. `PronounsTest` pins the whole path. Original ask below.


`ux/README.md` says it plainly under copy rules: *pronouns are a field. Half the copy on a
character sheet is written about them, so those strings need parameterising rather than
hardcoding.* `CharacterSheet` has no such field, and nothing else records one.

This is not only a UI concern, which is why it's here rather than in a design note. Every
character prompt renders a sheet, and with nothing to render the model infers pronouns from a
name — which is a guess, gets people wrong, and gets them wrong *in the fiction*, where it
reads as the story misgendering someone rather than as a missing setting. It also makes the
sheet's own copy ("what she won't do") either hardcoded or awkward.

Wanted: a `pronouns` field on `CharacterSheet` (free text, not an enum — the set isn't closed),
rendered into the character's context prefix and into the authored sheet's own labels, and
offered by `Autofill` when a sheet is generated. Cheap, and it stops being cheap to retrofit
once there are sheets and transcripts in the world.

#### 2.12 The world's cover is written, and must not spoil · **new** — ✅ **Shipped**
`cover` on both `WorldBible` and `CharacterSheet` (a character has the same problem — a stranger
reads a blurb before they take them), written by `Authoring.Cover.generate/2`. It is deliberately
*not* a field in `Autofill`'s spec: every other generated field is a fold over what's in the form,
while this one takes concealed material as input and can only be written once there is something
to cover.

The interesting half got a mechanical backstop rather than only a prompt. `Cover` checks the
returned prose against the secrets it was shown, retries once with a sharper instruction, and
returns `{:error, :leaked}` instead of a spoiler cover — a missing cover is recoverable, a
published one that gives away the twist isn't. The check catches **verbatim quotation** (a whole
statement, or a run of six consecutive words), which is the failure mode a model actually has with
a secret sitting in its context; `CoverTest` asserts both halves, and asserts out loud that
paraphrase is *not* caught, so nobody mistakes the floor for a ceiling. Original ask below.


The world bible's **cover** (`ux/polyphony-world.html` §Cover) is *the only part strangers see
before they take your world* — a short written blurb, not an image, generated from everything
below it *including the secrets*, with instructions to give none of them away.

`WorldBible` has no cover field, and `Autofill` has no such generation. The interesting half is
the constraint: this is the one generation whose input deliberately includes concealed material
and whose output must not contain it. That is a prompt-level obligation the rest of the system
solves structurally (a character is never *told* what they can't know), so it needs its own
care — and a test that a seeded secret doesn't survive into the cover.

#### 2.13 Deleted things really go, on a clock · **new** — ✅ **Shipped**
`Library.retention_days/0` is 30, `days_until_purge/2` rounds **up** (so a sliver of a day left
never reads as none) and bottoms out at zero rather than going negative, and
`Library.purge_expired/1` hard-deletes what is past the window. `Polyphony.Jobs.PurgeTrash` runs
it nightly off `Oban.Plugins.Cron` — that job is the whole point of the entry, because without
something arriving at the end of it the countdown is a claim again, which is the thing the design
set out to avoid. `trash/2` and `archived/2` are separate reads, because they're separate
shelves, and the library screen shows them side by side.

#### 2.14 Reading a sheet as of a past scene · **new** — ✅ **Shipped**
`Effective.sheet_as_of/4` folds only the canon arc extracted at or before a given stop, and
`Effective.scene_stops/2` gives the stops themselves — the scenes a character has *closed*, oldest
first, each carrying its own summary so a stop can be labelled without a second read. A summary
row is written at scene close and only then, so its existence is what "closed" means here, and
that is the right resolution: arc is extracted at close, so there is nothing to wind back to
between two of them.

Three edges a naive cut-off gets wrong, all pinned by `EffectiveAsOfTest`: hand-authored canon has
no source scene and so applies at every stop (otherwise the newest stop would disagree with
`sheet/3`, and the scrubber's right-hand end wouldn't be the sheet you have); arc from a still-open
scene belongs after every stop that exists; and an unrecognised scene degrades toward *less* arc,
because this backs a read-only preview where showing more than was asked for is a spoiler.

Alongside it, `ReadModels.Membership.scenes_for_character/2` and `scene_count/2` — distinct scenes
in first-entry order, so someone who leaves and comes back is counted once ("In 3 scenes" must not
count the door twice). Original ask below.


The character sheet's **scrubber** (`polyphony-kit.css` §9, `ux/polyphony-arc.html` "sheet time
travel") winds a sheet back — one stop per closed scene, because arc is extracted at scene close
and that's the only meaningful resolution.

Most of the data is already there: `arc_entries` records `source_scene_id` and `beat`, so the
history exists. What's missing is the read — `Effective.sheet/3` folds *all* canon arc with no
"as of" parameter. Wanted: `sheet_as_of(sheet, character_id, scene_id)` that folds only entries
canon at or before that scene, plus the ordered list of a character's closed scenes for the
scrubber's stops. Small, and it makes the arc screen's most distinctive control possible.

#### 2.5b Attaching a world copies it · **change** — ✅ **Shipped**
`Library.copy/3` is the primitive — the one shape behind every "this is a template"
relationship in the design — and `derived_from_id` (which the schema already had) records
the provenance, so `copies_of/2` / `copy_count/2` make *"used in 2 campaigns"* a real count
rather than a claim. `CampaignLive.select_world` copies on attach; re-selecting a campaign's
own copy doesn't copy the copy. `LibraryTemplateTest` pins each consequence the design
claims: editing the template reaches nobody already started, deleting it breaks nothing, and
the only route back is deliberate and takes a snapshot. The world screen states which side of
the relationship it is on rather than leaving it to be discovered. Original ask below.


A campaign does not reference a library world, it **copies it on attach**. Forced by 2.8: a
campaign accumulates world arc, and two campaigns cannot write different histories onto one
bible. Consequences:

- A library world is a **template**. Editing it never reaches a campaign already started from
  it, so there is no shared-artifact hazard, no copy-on-write escape hatch, and no
  delete-in-use problem — deleting a library world cannot break a running campaign.
- The honest cost: fixing a typo in the library copy doesn't fix the campaigns. The UI says so
  rather than implying live coupling.
- The only route back is deliberate — *save a copy to your library*, which snapshots the
  campaign's current version as a new template.
- Same logic applies to characters and groups: campaign-owned, never shared references.

#### 2.5c Finishing a campaign · **new** — ✅ **Shipped**

`Polyphony.Campaigns` — `status/1` derives `:unstarted | :playing | :finished`, and only
`finished_at` is stored, because "this story is over" is the one thing the data can't work out
for itself. `finish/2` deliberately does **not** archive: a finished campaign is the one you most
want to be able to find, to read back or to name as a prequel (§3.4). `reopen/2` because
concluding something is a judgement and judgements change. Closing an open scene stays the
caller's job through the normal path — a scene closing is an event, and this is a library write.

Also here, because the library's rows needed them: `pending_review/2` (a campaign's cast's arc
proposals plus its world's — the same number the scene gate blocks on, so the row doesn't
surprise anyone) and `by_character/2`, which is free because characters don't cross campaigns
(§2.7).

#### 2.8 World arc — durable world change, and who knows about it · **new** — ✅ **Shipped (A–D)**
Durable world-change entries (discovery/revision), parallel to character arc, proposed → canon
on review, folded into the world half of context. Global facts reach everywhere; local facts
only their scene location (§2.3); off-screen characters catch up by the fact being present in
their next scene (facts injected, reactions played on screen — no arc extrapolation). Reuses
`arc_entries` (`subject_type: "world"`) with `WorldArcExtractor` / `EffectiveWorldBible`;
shipped alongside wiring canon **character** arc into generation too (it was built but only
consumed by publishing). Review gained reject + edit. See `completed-roadmap.md`.

Two follow-ups it surfaced:
- **Arc/world-arc extraction metering** — ✅ **Done.** Both extractions now attribute to the
  campaign owner (`Attribution.for_scene`, `SceneClose.meter/3`); also fixed a latent
  `Costs.check` crash on a nil user id (org-owned / unattributed campaigns). "The owner owns
  everything autonomous in their campaign."
- **§3.0 gating** — ✅ **Shipped (MVP)**, see below.

### 3 · Publishing, continuity & knowledge

#### 3.1 Publication is a set of viewer perspectives · **new** — ✅ **Shipped**

`PolyphonyCore.Publication` — `perspectives` + `spectator` + `forkable`, stored **on the snapshot**
rather than the live campaign, because the snapshot is the thing readers hold and the grant must
not change under someone partway through. `Publication.viewer/2` is the entire seam: publication
decides *who you may be*, `Visibility` decides what that person sees. Settings a snapshot never
had read as spectator-only — the least-granting answer, not the most.

Rather than enumerating which authoring surfaces are published, **publication names the
perspectives a reader may adopt**, and `visible_to?/3` (§8) does the filtering it already
does in play.

- The publisher picks from the main cast plus omniscient. Publishing several perspectives is
  the product's showcase — the same scene from three heads, switchable — and nothing else on
  the internet reads quite like it.
- **This is the spoiler control, not a reading preference.** Omniscient exposes every private
  thought; if a character is secretly working against the others, publishing omniscient hands
  that away on page one. Only the author knows which perspectives are meant to be read.

**Why perspectives rather than per-surface toggles.** Triggers, events, and location state are
all coming, and any of them can carry spoilers. Enumerating surfaces means every new feature
ships a new toggle and the defaults rot. Filtering by perspective covers surfaces that don't
exist yet, for free — provided one rule holds:

> **Any new authoring surface must declare its visibility, and defaults to invisible.**
> Anything that forgets to declare is unpublished rather than leaked.

**Two things sit on top of perspectives, as separate opt-ins:**

- **Character sheets.** "You may read as Wren" and "you may read Wren's sheet" are different
  permissions — the sheet holds her concealed facts, her boundaries and her initial knowledge,
  which spoil forward rather than sideways. Off by default.
- **Forkable.** In practice this means everything, including arc, since a fork must be able to
  continue the story. Note that a "don't fork" flag on fully visible material is unenforceable
  — anyone can retype it. What protects an artifact is not publishing it, so forkability is
  the top of the ladder rather than an orthogonal switch.

**No per-artifact privacy for campaign contents.** Publishing is one campaign-level decision
covering everything inside the snapshot, so nobody ever sets visibility on forty walk-ons.
Library-entry visibility (§7) stays a *separate* system for the different job of sharing a
single character or world on its own — the two look similar and must not be merged.

**The two systems can't contend**, because they govern different objects: publication grants
access to the frozen snapshot's embedded copies, library visibility governs the live entry.
Reading a published campaign never reaches the author's live world. Browse should be explicit
about which one a reader is looking at.

#### 3.0 Arc review gates the next scene · **new** — ✅ **Shipped (MVP)**

Opening a new scene requires that **every character being cast has no pending arc proposals**.
World arc gates the whole campaign, since it feeds every generation in it.

> **Shipped (MVP).** `Authoring.SceneGate.check/3` — per-cast (keyed by character *name*, the id
> scenes and extraction use), world arc campaign-wide; `campaign_live` consults it before
> `OpenScene` and redirects to arc review on a block; `ArcReviewLive` resolves cast ids → names
> (it was querying by id and finding nothing) and gained **accept-all**. See `completed-roadmap.md`.
> **Refinements not yet built:** the "extraction failed → block with retry" and "extraction still
> running → not ready yet" async states (they need extraction status tracking). The proposal gate
> is the correctness core; these are UX polish on top.

**Why.** Every unreviewed proposal is a gap between who a character is on paper and who they've
become in the story, and generation works from the paper. Let it run five scenes and the Director
is writing someone who stopped existing in scene 2. It also keeps an author's bookkeeping current,
which a writing tool should do regardless of any model reason.

**Scoping is what makes it tolerable:**

- **Per-cast, not per-backlog.** Nineteen pending across three scenes doesn't block a scene with two
  clean characters. Evaluate against the selected cast at scene setup.
- **Accept-all is the intended fast path, not a loophole.** The gate exists to keep state
  consistent, not to force careful reading. One tap still produces a sheet that matches the story.
- **A failed extraction does block, and that's fine.** No cast-anyway hatch. Extraction failures are
  overwhelmingly provider rate limits, which means turn generation is failing too — letting someone
  into a scene that can't run would be a worse experience than the block. Retry is the only action,
  and the copy should say why: the model is busy, and a scene would struggle too.
- **One escape hatch, not two.** Accept-all without reading is already the cheap path out of a
  block. A second bypass would only be used to avoid the first.
- **Never blocks the open scene**, only opening a new one — and the currently open scene closes
  normally regardless.
- **Extraction is async**, so immediately after close there is a *not ready yet* state. That's a
  wait with an explanation, distinct from a block with nothing to act on.

Depends entirely on 5.1 — scene-close fan-out has no caller today, so there is nothing to gate on
and this cannot be built until that's wired.

#### 3.0b Group arc, and how it reaches members · **new** — ✅ **Shipped**
`Polyphony.Authoring.GroupArc`: `fan_out/3` writes one proposal against the group (filed under its
own `subject_type: "group"`, so a pending group change doesn't block a scene the group isn't in)
and one per current member, through the same review gate as anything else. `pending/2` and
`counts/2` back the collapsed card; `accept_all/2` is its one fast path. Nothing propagates
silently, which is what makes dissent free — refuse one member's and you have written the person
who didn't go along with it. Off-screen members are included, and so is someone who joined by hand
and was never seeded from the group. `ArcReviewTest` pins each claim. Original ask below.




**Prerequisite shipped.** Groups existed only in the design until the frontend rebuild reached
the campaign screen and found the Groups tab had nothing behind it — the backend-asks pass had
recorded group *arc* without recording that groups themselves weren't built. `Polyphony.Groups`
+ `Authoring.Group` now cover the artifact: a character-shaped template stored as a library
entry (kind `"group"`), live membership by stable id, and writing a character from a group
(seed + join). Detail in `completed-roadmap.md`. What follows is still open.

A group is a character-shaped sheet (2.5 / character authoring), so it can be revised by play the
same way a character is — a different prompt over the same extraction.

But groups **seed by copy**, so updating the template only reaches people written from it later.
For current members, a group-targeting change **fans out**:

- **One proposal against the group template** — affects future members only.
- **One proposal per current member**, generated for that character and reviewed individually
  through the normal path. Includes members who joined by hand rather than being seeded, since
  membership is what matters, and members who weren't in the scene, same as a world fact.

**Consequences worth keeping:**

- **Nothing propagates silently**, which is the rule everywhere else.
- **Rejecting one member's proposal while accepting the group's is how dissent gets written.** The
  one who didn't go along with it falls out of the review UI rather than needing a feature.
- **Review must collapse the fan-out into one card**, or a group of twelve floods the queue from a
  single event. One unit, one accept-all, expandable per member.
- **Gating (3.0) applies to the member proposals, not the template.** A pending template change
  blocks nobody, since it only affects characters who don't exist yet.

**Also still open: an audience that names a group.** `Group.secrets/1` gives a secret somewhere
to point, but a `Fact` still carries only `concealed: true` — there's no audience field, so
nothing yet *points*. Pointing one at a group and resolving it **when a character enters the
story** (which is what makes a scene-9 walk-on arrive already knowing) is the audience-picker
work: it needs `Visibility` in the loop, not just `Groups`. That's the piece the
`polyphony-audience-picker.html` mock depends on, and the reason its inherited-tick treatment
(`.chk-via`) can't be built yet.

#### 3.1b Limited omniscient — the published reading mode · **new** — ✅ **Shipped**

Two new viewer values on `Visibility`, and neither loosens anything: `{:readers, ids}` is a
**union over the existing character predicate** (so it inherits default-deny and cannot drift from
what those characters actually knew), and `:spectator` is its own default-deny clause with
whispers denied *ahead* of the general speech clause. Both are reachable only through a published
snapshot; nothing in play produces them.

*Highest-value item in this cluster.* A reader who just wants the story shouldn't have to choose a
character or settle for a camera. **Limited omniscient blends every published perspective** — the
union of what the shared cast knows, and nothing beyond it.

- It's how prose fiction is actually written. Narration without interiority is a screenplay, and a
  transcript of speech and action is a worse read than either.
- Implementation is a union over the existing predicate rather than a new projection: visible if
  visible to *any* granted perspective. No new visibility semantics.
- **Visually it's a character read, not an author read.** It gets the Page register, not the
  omniscient authoring treatment — it isn't an authoring surface, it's a way of reading.
- Should be the default offer where the publisher grants more than one perspective.

**Spectator is a real option but not the expected read**, and publishers can opt out of it. It is
the default only because it is the one setting that reveals nothing.

#### 3.1c Publication is two independent settings · **change** — ✅ **Shipped**

*Supersedes the four-rung ladder in an earlier draft, which conflated two unrelated decisions.*

- **How it's read** — a content decision: which perspectives are offered (spectator, limited
  omniscient, named characters). Any combination, including leaving spectator out.
- **Forkable** — a permission decision: one checkbox. Character sheets come with it, because a fork
  must be able to continue the story and can't from prose alone. Not a separate rung.

Consequence: **characters are not publishable on their own.** They travel only inside a fork, since
a character lifted out of their campaign has no history and knows nobody — which is the same reason
cross-campaign import is out of scope (2.7). Browse lists stories and worlds, not people.

#### 3.1c-ii Unreadable scenes must be detectable at publish time · **new** — ✅ **Shipped**

`Publication.unreadable_scenes/2` + `Publication.Preflight.warning/2`, shown live on the campaign's
publish panel as the grant changes. It warns and never blocks — sometimes a gap is the point.
`modes_for_scene/3` keeps the reader's current perspective **last rather than removed**, so the
control never reorders under them.

Falls out of 3.1c: if spectator is off and a scene contains none of the published cast, **no reader
can open it**. That's a legitimate authorial choice — a gap can be the point — but it must not
happen by accident.

- **Publish needs a pre-flight check** listing scenes no granted perspective can reach, with the two
  obvious fixes offered (turn spectator on, or share one of the people who were there).
- **Unreadable scenes still appear in contents**, marked. Silently omitting them would make the
  numbering lie and the story jump.
- The perspective selector on a given scene is **filtered to perspectives that can show it**, with
  the reader's current one listed last rather than removed — so the control never reorders under
  them.

#### 3.1d Group copies by their root · **new** — ✅ **Shipped (the identity)**

`root_id` on every library entry, stamped at insert (an original is its own root) and carried
forward by `Library.copy/3` — so a fork of a fork still groups under the thing it all started
from, which a parent pointer alone can't tell you. `Library.family/2` is one indexed read;
`Library.provenance/2` walks back to both the parent and the original. Browse groups by it. The
library's by-campaign version grouping is still to do.

Every campaign copies its world (2.5b) and every fork copies everything, so within a year there are
a dozen artifacts called Saltmarch. Flat lists become unusable.

- Needs a **root identity** on derived artifacts, not just a `derived_from` parent pointer — walking
  the chain per row to group a list is the wrong shape.
- **Library groups versions by campaign**; one row that expands, not four rows with the same name.
- **Browse groups forks by author**, because three forks share a title until someone renames one.
- `derived_from` is already stored on every derived entry and has never been displayed. Show it: a
  reader should always be able to walk back to where something started.

#### 3.1f A campaign has one published copy, replaced on republish · **decision** — ✅ **Shipped**

Publishing produced a new frozen entry each time, so republishing after playing on left every
link, bookmark and share URL pointing at the version somebody happened to start — and browse
showed the *oldest* publication as the story with the newest listed under it as "1 other version".

**Author call:** one published copy per campaign, replaced in place. The alternative accumulates a
copy per publish that nobody reads again, and keeping the id is what makes *carry on reading* land
on the continuation. The entry stays `frozen: true` — that axis means *self-contained*, embedding
pinned dependencies rather than referencing the owner's working set. What changed is that the
published copy is **replaced**, not versioned.

The accepted cost, stated rather than designed around: a reader partway through can have the story
change under them. In the ordinary case (the campaign grew) their place is re-found by scene id —
the event-store stream id, stable across republishes — so they simply see more of it. When a scene
they were on is gone, the shelf says so instead of quietly starting them over.

Two consequences worth keeping straight:

- **Republishing is not an appeal.** A take-down hides the campaign *and* its published copy, and
  `publish_campaign/2` returns `{:error, :hidden}` for either. Before the copy was replaced in
  place, pressing Publish again minted a fresh public entry and put the taken-down story straight
  back in browse — the hole this design closed rather than opened.
- **A take-down removes the thing, not its listing.** `hidden_at` is now a default filter in
  `LibraryEntry.visible/2` alongside archived and deleted, so a taken-down artifact is gone from
  its owner's library, not merely from browse — the deleted experience, with copy that says why.
  `take_down/4` hides the reported entry and everything of the **author's** it belongs to; only
  *other people's* forks go to the review lane, since those may have diverged past anything
  objectionable. Two reads opt back in and say so: the §C moderation grant (whose whole purpose is
  reading what nobody else can) and an account purge (which has to be complete).
- **`derived_from_version` is attribution, not reconstruction.** A fork is a full copy and there is
  no version history to rebuild a source from, so a replaced publication doesn't invalidate
  anything: the fork still records which story it came from.

#### 3.1e Reading position on a published campaign · **new** — ✅ **Shipped**

`Polyphony.Reading` + `Reading.Bookmark` — scene, beat and **perspective** together, because
perspective is part of where you were: coming back into a different head is coming back to a
different story. Stored as a `"bookmark"` library entry owned by the *reader*, one per published
campaign (`mark/4` moves the existing one rather than stacking), pointing at the **frozen
published entry** rather than the author's live campaign.

`shelf/2` returns `:reading | :finished | :gone`, and `:gone` **keeps the row** — unpublishing is
usually temporary and losing someone's place isn't recoverable from their side. Readability is
default-deny: anything not positively public-or-unlisted-and-live reads as gone, so a stale row
can never offer a link into somebody's unpublished draft.

*Carry on reading* now resumes at the bookmarked scene **and perspective**: all three parts of the
bookmark ride in the URL, and `Publication.to_param/1` / `from_param/1` are the single shared
vocabulary so a perspective round-trips identically through storage and through a query string.
The front page picks the bookmark over its own default, because coming back into a different head
is coming back to a different story. The link carries an intent, never an authorization — browse
re-checks the grant, so a perspective the author has since withdrawn falls back rather than
opening.

#### 3.3 Selective starting knowledge · **new** — ✅ **Shipped (unscoped audiences)**
`Polyphony.Authoring.Audience` — group ids + character ids, unioned, resolved **live**.
It hangs off `CharacterSheet.Fact` and `WorldBible.Entry`, which is the design's *one control,
three places*, and `PolyphonyWeb.AudiencePicker` is the single implementation both editors call
with a different header.

The shape avoids the matrix the ask warns about, exactly as specified: authored **from the
secret's side**, so it scales with the number of secrets rather than secrets × cast. "Everyone"
is deliberately not a stored value — it is the item's `concealed: false` state, because two
representations of one idea is how they drift apart. Additive only: an inherited tick can't be
individually removed, and the picker says so.

**Groups are named, not expanded.** Resolution reads current membership at the moment the question
is asked, which is what makes a walk-on written into the Tidewatch in scene 9 arrive already
knowing, with nobody assigning anything.

**And it reaches the prompt**, which is the only reason it was worth building: `Context.materialize`
takes the campaign `:cast` and tells a character the secrets their audience puts them in on —
rendered into the same "You know:" block §6.1 already describes, so the prompt shape is unchanged
— and `WorldBible.known_to/3` does the same for world entries. Absent a cast it is default-deny.
`AudienceTest` pins the path end to end; the character-side read-back (§04) is a derived
projection, so one fact keeps one home.

**Still open:** *whoever was there* (needs a source scene, which nothing carrying an audience has
yet — it goes in with audiences on arc), audiences on **arc entries**, and **location** audiences.
The design checked the last one against the component and it needs no change to it. Original ask
below.




`initial_knowledge` (§4) is t=0 dramatic irony, per character. What's missing is the ability
to say **which other characters are in on a given secret** — not everyone starts equally in
the dark.

The naive shape is a matrix of every concealed fact against every character, and it gets
unusable immediately. The design deliberately avoids that:

- **Unscoped audiences exist and matter.** `Everyone` (common knowledge, no setting attached) and
  `whoever was there` (resolves to a scene's cast) are audiences like any other. Together they
  make *secret* shorthand for *an audience narrower than everyone* — one mechanism, not two — and
  they cover the world-arc reach question without waiting for locations. "The whole town" is a
  location audience later, not a special case now.
- **Authored from the secret's side.** A fact marked `concealed` gains one control — *who else
  knows* — defaulting to nobody. Scales with the number of secrets, not secrets × cast, and
  matches how people think: invent the secret, then decide who's in on it.
- **One fact, one home.** The fact lives on the character it's about; knowledge propagates from
  there. You never author "Ilias knows about the cargo" on Ilias, so nothing can drift.
- **Two states only: knows or doesn't.** No "suspects," no "believes the wrong version" — a
  false belief is simply a fact about the believer (*Ilias is certain the cargo was
  legitimate*), which the existing model already expresses and which reads better for being
  concrete.
- The character-side view — what does Wren know — is a **read-only projection** of those
  lists, not an editing surface.

Nothing appears on unconcealed facts, so the sheet doesn't get heavier for the common case.

### 4b · Accounts

#### 4b.1 18+ is eligibility, not a content ceiling · **change** — ✅ **Shipped**
Reframed attestation as account eligibility (not a content layer); pinned the no-row /
no-invite-burn guarantee with a test; `Content.Floor`'s `attested` branch stays a latent
under-18 seam. See `completed-roadmap.md`.

Under-18s cannot use Polyphony at all. Supporting them would require parental controls and
in-house filtering — a large piece of work deferred a long way out. So:

- **An unchecked attestation ends the signup**, it doesn't restrict what the account can contain.
  Everyone with an account has attested, which is what makes the floor trivially satisfied rather
  than a no-op by accident.
- **Refusing someone must not create a row about them.** No email, no name, no consumed invite
  code. A local flag on the device is a sufficient best-effort block; keeping records on someone
  just refused is the wrong trade and creates PII we have no reason to hold.
- **A refused signup doesn't burn the invite code.**
- The floor layer stays in the model for when under-18 support is eventually built. It just isn't
  doing per-user work today.

#### 4b.2 There is no automated safety analysis to opt out of · **change** — ✅ **Shipped**
Removed the settings "opt out of proactive analysis" control (no automated analysis exists to
opt out of); the §C domain seam stays latent for when the feature lands (per campaign, per the
design). See `completed-roadmap.md`.

**What will be needed later**, and shouldn't be conflated with it: an opt-in for experimental
generation behaviour. That may belong **per campaign** rather than per account, since it changes
how a specific story plays, and it arrives alongside a profile page.

---

### 5 · Pre-existing, high priority

#### 5.1 Scene-close fan-out is never triggered · **wiring** — ✅ **Done**
Not from this design pass — flagged in the catalog (§8). `SceneClose.enqueue` had no caller
and `SceneClosed` didn't trigger it, so **per-character summaries and arc extraction never
ran in production.** The whole memory and arc layer was dark until this was wired.

**Wired** by `Polyphony.SceneClose.Handler`, a `start_from: :current` Commanded handler on
`SceneClosed` that calls `enqueue/2` (jobs resolve the configured provider/embedder at run
time). Supervised alongside the projectors and off in tests for the same reason (its
`Oban.insert!` touches Postgres); tests drive `SceneClose.run/2` and the handler's `handle/2`
directly. `start_from: :current` so a deploy doesn't re-summarize every historically-closed
scene.

Everything the design does with Arc Review was decorative until this. World arc (2.8) lands on
top of it, so this was a prerequisite for that too.

#### 5.2 Character identity is a name, not a stable id · **change** — ✅ **Shipped** (phases 1–4; §5 open)
`character_id` in the event log is the character's **display name** — minted at
`EnterCharacter{character_id: char_name(c)}` and keyed on with plain string equality through
*every* play-side subsystem: scene/beat aggregates (members/cast/completed/failed sets),
membership intervals, visibility (interior events **and** whisper `addressed_to` matching),
`packet_id = "#{scene}-#{beat}-#{character}"` (+ reroll/next-attempt), arc `subject_id`, the
Director roster/casting, and broadcast topics. The only id-keyed character reference in the
codebase is `Relationship.target_id` — the pattern the rest should copy: **store the id, carry
the name for display, resolve through the id.**

**The hazard.** Renaming a character that's already in scenes silently corrupts it: cold-cache
context rebuild (`Rebuild.find_sheet` name-matches) falls back to a bare prompt (no sheet, no
arc, no boundaries); membership/CommitPacket guards reject the new name as `:not_a_member`;
the character stops witnessing its pre-rename history and whispers misroute; accumulated arc is
stranded under the old name; re-roll/edit of pre-rename turns fail on `packet_id`. Today two
things keep the door shut: `name` is **not** in `EffectiveSheet.@overridable_scalars` (so arc
can't rename), and there's no bulk-rename flow — **but the sheet editor writes `name`
unconditionally with no in-play guard.**

**The fix (bounded, but real).** Mint `character_id` as the library id at the single source
(`campaign_live` scene-open + `seed_context`), add an **id↔name translation layer** where the
fiction is rendered to / emitted by the LLM (the log stores ids; the prose still speaks names),
simplify `find_sheet`/arc lookups to id, and provide a **dual-read shim** for legacy name-keyed
streams/`scene_memberships`/`arc_entries.subject_id` (events are immutable — rule 6).

**Design decision (author):** *every* sheet field should eventually be arc-overridable — including
`name` — except **boundaries** (which get their own events/functionality). So the goal isn't to
lock the rename door; it's to make identity stable enough that rename (via arc or the editor) is
safe, then open all non-boundary fields to revision.

**Phased execution** (each phase tested + committed; every translation legacy-tolerant — an
unmapped id renders as itself and an unmapped name resolves to itself, so old name-keyed data and
the existing suite stay green):

1. **Sheet-lookup id-tolerance.** ✅ **Done.** `Rebuild.sheet_for` resolves by library id first,
   then the legacy name match. Rename-safe lookup; no visibility impact.
2a. **`Scene.Cast` resolver.** ✅ **Done.** id↔name maps for a scene (`render_name`, `resolve_id`)
   with identity fallback.
2b-render. **id→name in prompts.** ✅ **Done.** `context` (live events, recent scenes, membership)
   and `scene_brief` (roster line, transcript, whisper addressees) render display names. Display
   only — no routing impact; suite green on identity fallback.
2b-emit + 3. **The atomic remainder.** ✅ **Done** (with the frontend rebuild). Emitted
   names resolve to ids and the mint flipped in one change, because `addressed_to` could
   only become ids once viewers were ids too. Landed: `Cast.resolve_addressees/2` at every
   packet-production point (generation, the composer, edit, an accepted draft, a
   user-controlled slot); the Director's cast picks resolved before `declare_turn_order`;
   `EnterCharacter{character_id: <library id>}` at both mint sites (campaign scene-open and
   play's admit); and an id-native `play_live` — viewer, roster `<option>` values, speaker,
   control modes and whisper parsing all keyed by id, with names rendered at the edge.
4. **Arc + gate by id.** ✅ **Done** (same change). `arc_entries.subject_id` is the library
   id, so the arc-review screen and `SceneGate` dropped the name-resolution dance they used
   to need; names are labels again.
5. **Open the fields.** ⬜ **Open.** Make `name` (and other non-boundary scalars) freely
   editable + arc-overridable, now that identity is stable. The rename-safety tests
   (`PlayIdentityLiveTest`) are the guard this phase builds on.

**Data.** Cleared rather than migrated — events are immutable (rule 6), so there is no
in-place rewrite of `character_id`, and a half-keyed scene is worse than either scheme.
`Polyphony.SceneReset` / `mix scene.reset` drops every stream and scene-derived read model
and keeps the library (characters, worlds, campaigns).

**Sequencing decision (author), as executed:** the atomic remainder was deferred to the
frontend rebuild rather than overhauled then discarded — its biggest piece was a `play_live`
overhaul the redesign would rewrite anyway — and landed there, built id-native. The
corruption risk is **closed**: a rename now changes only what's displayed, pinned by
`PlayIdentityLiveTest` (a whisper still reaches its addressee after the target is renamed,
and a bystander still can't see it). What's left is phase 5, which is a feature rather than
a risk. Detail in `completed-roadmap.md`.

---

---

## Housekeeping

### Documentation reconciliation
Split `roadmap.md` into the near-term schedule (`roadmap.md`) and post-v1 strategy
(`decisions.md`); moved the design's backend asks to `docs/backend-backlog.md` (renamed from
`ux/backend-asks.md`); archived the superseded mock-thread brief to `ux/archive/`; added
`docs/README.md` (the doc index + boundary map + "where new content goes"). CLAUDE.md now
describes the `ux/` design kit and the port-from-the-kit rule.
