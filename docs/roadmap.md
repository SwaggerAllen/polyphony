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
  → defaults. *Deferred:* wiring `record/2` into the live generation path and the resume/raise-cap
  UI (the breaker + ledger are here).
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
- **B8 — Character stubs.** ✅ **Done.** `CharacterSheet` gains `status: :stub | :proposed |
  :full` + a one-line `role`. `Polyphony.Authoring.Stub`: `new/3` makes a stub (name + role +
  inbound relationships, no sheet); `promote/2` generates a full sheet from the stub + context
  and gates it `:proposed` (pluggable `:generator`, default the LLM, so it runs offline);
  `accept/1` is the review gate → `:full`. Casting a non-`:full` character is refused by
  §B7 (`:stub_needs_promotion` / `:needs_promotion`). Mirrors locations' `origin: :discovered`.
  *Deferred:* the inline-create + promotion-review UI, and Director `:novel`-proposal stub creation.
- **B9 — Soft-delete.** Archive (recoverable) vs delete (confirmed, recovery
  window); published-content deletion resolves the snapshot; forks survive.

---

## §C — Cross-cutting data-handling

Because content is stored unencrypted and the operator is a data controller:

- **Reactive vs proactive access split** — a report grants full-account visibility
  (logged/attributed, reachable only via the report); proactive analysis is
  opt-out-able at account + campaign level and **must not** be enforced against
  report-triggered investigation.
- **Opt-out flags enforced at the data layer** (query time), not just UI.
- **Retention & deletion** with real windows and limits (published forks survive,
  backups, legal holds).
- **Admin audit log** persisted, covering all content access.
- **Consent versioning** persisted, tied to policy versions.

---

## Planned additions (this session)

1. **User-stipulated turn order + character removal per beat** → folded into **A1**
   (explicit turn-order event; re-roll reads declared order).
2. **CLAUDE.md / architecture.md / this roadmap** → ✅ done.
3. **DigitalOcean App Platform deploy + setup doc** (DO managed Postgres + pgvector,
   migrations on deploy, DeepInfra integration + `DEEPINFRA_API_KEY`/model routing).
   Late milestone — needs the Phoenix web layer + release config first. The DeepInfra
   adapter already exists.
4. **First-user auto-admin + `superadmin` role** → folded into **B2/B3**.
5. **Invite-only sign-up (single-use links)** → folded into **B2**.

---

## Frontend (LiveView) — FS view inventory

Not started. V1 Play + a debug drawer is the minimum viable frontend (everything
through backend slice 6 is exercisable from it). Principles: every event-rendering
view is viewer-parameterized through `visible_to?`; occlusion is silent in
production; render committed packets, never tokens; three distinct waiting states;
mobile-first.

V1 Play · V2 Scene Index & Branch Navigator · V3 Character Inspector · V4 Sheet
Editor · V5 Arc Review · V6 World Bible Editor · V7 Location Graph · V8 Campaign
Setup · V9 Library · V10 Settings & Cost · V11 Auth · V12 Account & Profile ·
V13 Admin & Moderation. Prompt-template editor (V10.1) uses `solid` (sandboxed
Liquid).

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
6. **Frontend (LiveView)** — layered on the per-viewer broadcaster seam.
7. **Deployment** — DO App Platform + setup doc, once the web layer exists.
