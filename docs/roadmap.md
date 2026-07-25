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

- **B1 — Ownership, visibility, publish snapshot.** Owned entities + `:private` /
  `:unlisted` / `:public`; publish = self-contained frozen copy (pinned sheet/bible
  versions + frozen arc snapshot, canon-only by default); copy-on-fork/instantiate
  (fork = instantiate a whole campaign's embedded contents); `derived_from`
  attribution. Large; gates public features.
- **B2 — Auth, identity, consent.** Magic-link (email, no passwords) + numeric-code
  fallback; username (required at first sign-in, never expose email); 18+
  attestation (logged); versioned consent records.
  - **[planned addition #4]** roles `user` / `admin` / **`superadmin`**: first
    sign-up → superadmin; admins can promote to admin; superadmin promotes/demotes
    admins and is itself un-demotable.
  - **[planned addition #5]** **invite-only sign-up** — single-use invite links
    (admin-generated) gate account creation; the first user bypasses. Free tier /
    subscription tiers become a future addition.
- **B3 — Admin, moderation, reporting.** Server-side admin authz + audit log; report
  table (CSAM / real-person lines first); admin email alert per report; takedown /
  dismiss / warn / suspend; absolute-line takedown flags the account.
- **B4 — Notification infrastructure (minimal).** Build the sending path + prefs
  surface (mostly stubs); v1's one live trigger is admin report alerts. Email only.
- **B5 — Cost caps / circuit breaker + per-user accounting.** Per-user spend
  ledger (billing-ready); per-day/per-campaign ceilings; soft warning + hard stop
  that pauses generation.
- **B6 — Export.** Campaign transcript (markdown, omniscient) + JSON (event log +
  pinned deps); **per-perspective export** (the filtered projection as a character);
  sheet/bible JSON; offered in library + delete-confirmation.
- **B7 — Manual scene control + Continue.** Direct add/remove character
  (`CharacterEntered`/`Exited`, author lever, at beat boundary); Continue = empty
  user turn. Cheap, high-value.
- **B8 — Character stubs.** `status: :stub | :full`, promotion generates a full sheet
  behind a `:proposed` review gate; casting a stub prompts promotion (mirrors
  locations' `origin: :discovered`).
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
