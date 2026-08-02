# Polyphony — Post-v1 Decisions & Strategy

**What this file is.** The design decisions and strategy settled for features **beyond v1** —
the reasoning behind what's *not built yet*: monetization shape, TTRPG resolution, kids/org
products, style material, and the ordering logic that ranks it all. This is the **forward
rationale** half of the docs.

**How it differs from its neighbours.** `roadmap.md` is the near-term *schedule* (what ships
next, in what order); this file is the *why* behind the post-v1 horizon. `architecture.md` is
the as-built rationale (why the shipped system is shaped the way it is); this is its forward
mirror. `backend-backlog.md` is the concrete engineering worklist; this file is the strategy
that worklist serves. See `docs/README.md` for the full boundary map.

**Status:** this is a hypothesis-ordered roadmap, not a commitment. Nothing here should be built
ahead of user feedback except the cheap/latent items and the pre-monetization harness. The real
value of this file is (a) sequencing and (b) recording the **seams v1 must preserve** so later
features are bolt-ons rather than rewrites.

---

## P1. Organizing principles

Five principles emerged that determine ordering more than any individual feature's appeal:

1. **Does it add an LLM pass?** Anything that adds inference on top of the existing per-turn cost
   is post-monetization (or post-BYO), because it multiplies the cost on the axis you can't yet
   charge for. This is the single cleanest sorting line in the whole roadmap.
2. **Is it pass-free measurement?** The harness must be pre-monetization (no stickiness without
   iteration; early adoption is all free-tier). The *pass-free* half of the harness
   (branch-and-compare, human rating) ships early; the *pass-heavy* half (LLM-judge scoring) is
   post-monetization.
3. **Is it latent in the architecture?** Several features are nearly free because v1's structures
   (event log, viewer-parameterized projections, ownership/fork model) already support them.
   These are cheap wins, low risk.
4. **Does it gate other things?** Two surfaces turned out to be wide gates: the **moderation
   surface** (gates everything social/public) and **BYO-endpoint** (unlocks pass-heavy features
   and relieves the multiplayer cost tail).
5. **Is it a separate product on the same engine?** Two directions (kids mode, org/enterprise)
   are not features but distinct products forking v1's core regimes. They get their own phases
   and their own seams.

---

## P2. Seams v1 must preserve

The through-line of the whole design has been *build the seam, not the feature*. These are the
seams that keep post-v1 work cheap. **If v1 violates one of these, the corresponding later
feature becomes a rewrite instead of an addition.**

- **Viewer-parameterized event stream** (already in v1) → spectating, replay, multiplayer. Never
  hardcode omniscience into the transport; a viewer is a value.
- **Control-assignment model for characters** (already in v1) → multiplayer. A user-controlled
  character is structurally what a second human occupies.
- **Provider/model adapter boundary** (already in v1) → BYO-endpoint. Keep generation behind an
  OpenAI-compatible contract that can be made per-user.
- **Owner as an indirection, not a hardcoded `user_id`.** ✅ **Done in v1** (ahead of the
  frontend, so the UI's ownership/authz is written against the seam the first time). `Polyphony.Owner`
  is a `{type, id}` value; `Library` stores `owner_type` + `owner_id` and its API takes an `Owner`
  / `%User{}` / bare id (coerced to `:user`, the v1 default). `Library.Access` owns *user*-owned
  entries by actor match and **default-denies** an org-typed entry — org membership resolves
  through a permission layer that stays a deliberate later addition (§P8). Only content ownership
  is polymorphic; actor/reporter/recipient references stay user-shaped. Adding orgs is now "add an
  owner type + a permission layer," not a schema-wide migration.
- **Notification infrastructure** (stubbed in v1 for admin alerts) → subscriptions, digests.
- **Resolution as an interface** (design decision, not yet built) → TTRPG systems. When dice are
  built, build a resolution *interface* (intent + state + difficulty → outcome + degree) with the
  existing implicit "Director decides" as one implementation, so rulesets are swappable.

---

## P3. Roadmap (tiered)

### Tier 0 — Cheap & latent (strap-on candidates)

Architecture already supports these; low risk, low cost, several are differentiating.

- **Relationship / arc visualization over time** — read model over directional relationships +
  arc entries already stored. No new writes.
- **Retroactive per-perspective replay** — "replay this arc as Mira"; generalizes the
  per-perspective export into a viewing mode.
- **Realtime spectating — capability only** — live viewer subscription on an active, non-fork
  campaign; nearly free alongside replay (same read model, live cursor instead of historical).
  *The product/monetization version is Tier 3; this is just the plumbing.*
- **Author-style presets** — hand-authored genre/register presets in the prompt-template layer.
  Pass-free, no legal exposure, immediate quality lever, seeds the style-object work in Tier 1.

*(The consistency guard was considered here but moved to Tier 3 — it adds an LLM pass.)*

### Tier 1 — Style objects + pass-free harness (pre-monetization; the stickiness layer)

This is the cluster that earns retention. Style-as-object and the harness are effectively **one
initiative**: making style a first-class object is what makes writing quality an *isolable*
variable, which is what the harness needs to measure.

- **Style specifications as ownable / forkable / publishable artifacts** — the three-birds item:
  a differentiating feature, an isolable quality variable, and half the harness. Rides the
  existing ownership/fork model. A style object composes with any setting.
- **Branch-and-compare harness** — same committed prefix, two variants (style / prompt / model),
  human picks. Pairwise preference is the reliable subjective-quality signal, and v1's branching
  already produces the matched pairs. **Pass-free** (you were generating the continuations
  anyway; you're capturing a preference).
- **Blind-pick-as-feature** — surface the comparison as an occasional "pick the continuation you
  prefer," so preference data is a byproduct of enjoyable use, not a labeling chore.
- **Human-rating absolute gauge** — periodic human rating / holdout viewed directly. Pass-free.
  Necessary because pairwise preference tells you *which is better*, not *whether either is good* —
  it measures slope, not altitude, and is blind to slow uniform drift.
- **Memory-quality tuning surface** — expose/tune the retrieval-vs-recency gradient from the
  design brief. Belongs here because it's a quality knob whose effect you can now *measure*.
- **Character authoring guidelines / boundary defaults** — a reviewable set of **default authoring
  guidelines** applied at character creation, a sibling to the style object (*in addition to or as
  part of the writing-style artifact*). E.g. *every character has explicit romantic & sexual
  boundaries*; *every character has a threshold at which they'd betray their ideals/principles*.
  Ships as **reviewable defaults** the author accepts or overrides, so characters aren't flat and
  safety-relevant boundaries are never left implicit. Composes like a style object
  (ownable/forkable), feeds the Director/generation as conditioning, and cross-links the
  consent/safety model (§B2) and the moderation surface (Tier 2). Not yet designed — the value is
  the *reviewable default set*, not any one rule.

### Tier 1.5 — BYO-endpoint (capability + economics gate)

Promoted from "business-model-gated" because three separate threads lean on it.

- **Per-user OpenAI-compatible endpoint** — the v1 adapter boundary made per-user.
- Unlocks the **pass-heavy feature class** for power users without you eating the cost.
- Is the **cost-relief valve for the multiplayer heavy tail** (see §P4).
- *Not* the multiplayer pricing mechanism (that's the token/slot model, §P4) — a common early
  confusion. BYO offloads *compute cost*; it does not answer *how revenue attaches*.

### Tier 2 — Big bets, ordered by expected impact

1. **Generation-quality pillars** (author-preference conditioning: pacing, prose density,
   interiority, tonal rules) — highest impact because every user feels it every turn, and Tier 1
   makes it measurable. This is the flywheel: measure → tune → measure.
   - **Prose-first generation + structured extraction** ⬜ **Planned — not yet designed.** Today a
     character turn is generated *as* a `TurnPacket` JSON (moves segmented as the model writes),
     which fights the model's grain — it produces flatter prose, and the model keeps wanting to
     emit prose anyway (the empty/markdown-response saga). The direction: **let the model write
     natural prose attached to a character, then split it into moves** (thought / speech / action)
     in a second, lightweight step. Prose reads better, and it removes a whole class of
     JSON-compliance failures. **The non-negotiable constraint:** the visibility guarantee (rule 3
     — dramatic irony is *structural*) turns on the exact bits hardest to infer from free prose —
     whisper vs. aloud, and addressee. So the split must **never infer** audibility/addressing: the
     generator marks those explicitly with lightweight, unambiguous markup (the composer's
     `(whisper to NAME: …)` convention already exists in `SayParser`/`TurnEdit`, and the §20
     ingestion layer already does prose→moves for *user* input — extend that machinery, don't build
     new). Recommended shape: **prose with minimal safety-markup → deterministic extractor**, not
     free prose → an LLM guesser. If a second LLM pass is used at all, constrain it to **extraction
     only** (verbatim spans + labels, never rewriting — paraphrase breaks verbatim integrity and
     the "prose the user read is canonical" property), and *still* have the generator mark whispers
     so no fallible step ever *decides* who-hears-what. Scope note: **character turns only** — the
     Director's output is a decision (cast/control/world-events), not prose anyone reads, so it
     stays JSON. Likely simplifies `self_state` (demeanor rides the narration; mood/intention shrink
     to a small sidecar or vanish). **Validate with the Tier-1 branch-and-compare harness** (same
     scene, JSON-first vs. prose-first-then-split, human picks) — the quality delta *is* the
     justification, so measure it before committing. Replay-safe: both steps live in the generation
     job and produce the same committed move-events.
2. **Moderation surface** — pulled forward because it **gates everything social/public below**
   (spectating-as-product, marketplace, creator economy, public profiles). Report queue,
   takedown, the report-pierces-visibility model, admin audit log. (Some of this is already in v1
   per `backend-delta` B3; this is the fuller build required before public browsing opens.)
3. **Multiplayer proper** — the most-prepared-for pillar (control-assignment, viewer
   parameterization, GM-as-Director-authority) and potentially the biggest differentiator, but a
   genuinely different product (presence, turn arbitration, async play, social dynamics).
   **Preceded by a dedicated monetization design pass** (§P4). Backend note from the design work:
   the Director must handle **multiple yields per beat** once multiple characters are
   user-controlled (already flagged in `backend-delta` A1).
4. **TTRPG resolution systems** — the dynamic resolution model (§P5). Impact is
   **audience-dependent** (higher if users skew game-y, lower if literary), which is why it sits
   below the two universal pillars. Pairs naturally with multiplayer. Note: conditional-boundary
   arc evaluation and per-check difficulty-setting add LLM passes → post-monetization.
5. **Voice / per-character TTS** — production-value differentiator, strong on mobile where
   reading is the friction. Additive polish pillar, not a capability pillar.
6. **Import / interop** — bring characters from tools users are leaving; acquisition wedge that
   scales with growth stage. The dynamic-sheet direction (§P5) makes ingesting foreign formats
   more tractable.

### Tier 2.5 — Social / creator prerequisite cluster (gated behind moderation)

These three are prerequisites for the creator economy and must land before it.

- **Following** — users and campaigns.
- **Batched, opt-in digest notifications** — e.g. weekly digests. Grows the admin-alert
  notification seed. *Batched-and-scheduled is the opposite of engagement-farming* (it respects
  attention rather than mining it), so it's not a red flag provided it's opt-in.
- **Full profile pages** — creator-first browsable surface (v1's public scope is content-first).
  Fields (username, display name, bio) are collected in v1; this builds the page.

### Tier 3 — Monetization-dependent & pass-heavy

- **Consistency guard** — validation pass flagging contradictions against structured facts. Adds
  a pass → here, not Tier 0.
- **Spectating-as-product + tipping** — reuses the Tier 0 plumbing but is an audience/monetization
  bet; the Twitch-for-this angle. Inherits *all* public-content moderation obligations plus live
  unreviewed risk, so it cannot precede the moderation surface.
- **Creator economy / marketplace** — published-content-as-marketplace; substrate (ownership,
  fork, attribution) exists, but requires the Tier 2.5 cluster.
- **LLM-assisted absolute scoring** — the pass-heavy half of the harness.
- **Style ingestion** (paste text → style object) — legal-gated (see §P6); a later enhancement to
  Tier 1's style work once there's budget for advice on the ingestion question.
- **Payments / subscriptions** — the monetization substrate itself (§P4).

### Tier 4+ — Separate products on the same engine

Each is a distinct product forking a v1 core regime. Own phases, own seams, gated on real
external inputs (legal advice, a first customer).

- **Kids-with-guardians mode** (§P7) — forks the data-*handling* regime.
- **Organizations / enterprise** (§P8) — forks the data-*ownership* regime.
- **Novelization / export-to-novel** (§P11) — a new *output* product: publish a finished campaign
  as a novel. New monetization stream (self-publishing). Late; not yet designed.

---

## P4. Monetization model (settled shape)

The economic model reached a clean, single-primitive shape. Record it because it should resist
feature-by-feature erosion.

### Primitives

- **Token bucket (recurring, per user, per tier)** — the metered unit. This is the thing that
  *costs* you, so it's the thing you meter. Users **contribute a portion of their token cap to
  their multiplayer games**, which is how "everybody pays for the shared game" works without a
  per-game transaction.
- **Multiplayer slot (recurring / monthly)** — the concurrency unit. A slot is a *subscription to
  ongoing capacity*, so it must be **monthly, never a one-time payment**. A one-time fee against a
  recurring token cost inverts the unit economics once amortized — that was the footgun; monthly
  pricing closes it.

### Why concurrency + consumption, not one or the other

- Metering **concurrency alone** (pure slot cap) leaves *your* cost unpredictable — one heavy
  six-character daily campaign can cost more than a dozen dormant ones, yet consumes one slot
  either way.
- Metering **consumption** (token bucket) aligns your cost with your charge.
- So: **token bucket = cost alignment; monthly slot = predictable, legible pricing surface**
  ("I'm in N games") that users can reason about. Both, composed.

### Tiers (shape, not final numbers)

- **Free tier** — generous *single-player* (bounded by token cap, self-limiting, no network
  cost). **No permanent free multiplayer game** — instead a **30-day free trial** of multiplayer,
  which monetizes the single-game crowd on a delay rather than subsidizing their most-expensive
  activity forever. Multiplayer's recurring cost means free multiplayer must be time-boxed.
- **Base paid tier** — includes real multiplayer. Treat multiplayer as
  **retention/acquisition that justifies the base subscription**, *not* as a slot-sales revenue
  line — slot expansion revenue only comes from the minority wanting multiple concurrent games
  (expected: most in 1, a minority in a handful). Price so the base feels like it *includes*
  multiplayer, with slot expansion as an enthusiast pressure-valve.
- **Minimal multiplayer** — a post-trial user who only wants their one game buys **one monthly
  slot + a recurring token contribution**. This is a coherent bottom tier, arrived at by removing
  mechanism (monthly slots) rather than adding a special "free user buys slots" path. Do **not**
  build a free-user-buys-slots path — a one-time slot purchase supplying free recurring tokens is
  the inverted-economics footgun.
- **Professional / heavy tail** — **BYO-endpoint or pay-as-you-go** as the escape hatch, so the
  full-time and very-heavy users don't run variable cost you eat under a flat slot price.

### The "active" definition (decide early; hard to change)

Define **active = generated a turn within a window**. **Auto-idle stale games**, freeing the slot;
one-tap reactivation if a slot is free. This single idle-transition serves **triple duty**:
engagement (don't count dead games), cost (a dormant game costs nothing, so shouldn't cost a
slot), and **billing lapse** (see below). That it serves all three is a sign the primitives are
right.

### Billing edges monthly pricing introduces

Monthly slots (unlike one-time) make **cancellation and downgrade** real states needing defined
behavior:
- Downgrade (3 slots → 1) or cancel → now-unfunded games use the **auto-idle/archive transition**
  (dormant, costs nothing, reactivates on re-subscription).
- **Grace window** on lapsed payment so a group's active campaign isn't destroyed mid-story.
- ⚠ An unhandled downgrade is how you accidentally delete someone's campaign — state downgrade
  behavior explicitly when billing is specced.

---

## P5. TTRPG resolution systems (settled design)

Not "add dice" — **make adjudication legible**: outcomes derive from stated, inspectable, evolving
character qualities instead of an opaque model call. Same philosophy as the visibility projection
(structural, not prompt-hoped).

### Deliberate scope choices

- **Cut social rolls** (persuasion/deception) outside the boundary mechanic. In tabletop they
  produce absurd outcomes by letting dice override fiction and character — the one thing this
  engine is best at *not* doing. Social outcomes stay with characterization + boundaries. Keep
  resolution for **physical / skill-based** action.
- Resolution plugs in as a **third stage between the two proposal stages** already in the design:
  mechanical filter (possible?) → **resolution (did it succeed, to what degree?)** → Director
  authors consequence. A failed roll is structurally a **proposal rejection with a number
  attached** — reuses the "rejection is a narrative beat" pattern.
- **Difficulty-then-roll-then-narrate**, not narrate-then-validate. Generation is *conditioned on*
  the roll (two passes: intent, then outcome), so the dice actually constrain the fiction rather
  than rubber-stamping prose the user already saw.

### Stakes require commitment (the philosophical crux)

- Dice and re-roll are the **same lever pointed opposite ways**. A roll you can re-roll isn't a
  resolution, it's a suggestion. So resolution requires a **commitment mode** that disables casual
  revision — this is the significant shift, and it's mostly **policy + UI**, not domain logic.
- Commitment can be **system-enforced** (single-player and clean multiplayer: nobody overrules,
  dice + stats are sovereign) or **GM-arbitrated** (a human holds override authority). Prefer
  system-enforced as default; the GM role is only strictly needed for multiplayer's "who
  overrules" social question.
- The **GM role rides the control-assignment seam** — a GM is a participant whose authority points
  at the Director instead of a character. Cheap domain-logic-wise; a real UI shift.
- ⚠ Commitment mode **breaks the safety of the edit/branch model** existing users learned. It must
  be a **loud, upfront campaign property** ("committed play: resolutions are binding"), not a
  subtle setting — a user who learned everything is revisable will read their first binding
  failure as a bug.

### Build order for this feature

1. **Resolution interface** (intent + state + difficulty → outcome + degree) with dumb GM-fiat
   behind it. Prove the seam.
2. **First concrete system end-to-end** (percentile / d100 — see below).
3. **Commitment mode** (policy + UI).
4. **Second system** (dice-pool) to prove the interface survives without spine changes.
5. **GM authority role** — only when multiplayer needs it.

### Dynamic system model (the ambition, mostly achievable)

Character sheets should be **dynamic typed stat collections seeded by system templates**, so a
sheet doesn't commit to a system — it holds traits + a pointer to the system that interprets them.
This *removes* the stickiness of the stat schema (it's data, not structure). Four layers:

| Layer | Dynamic? | Notes |
|---|---|---|
| Stat schema (sheet fields + ranges) | **Yes, trivially** | typed key-value bag, template defaults; adding an attribute = inserting a row |
| Dice / randomness source | **Yes, trivially** | a die is a named distribution `{count, sides}` / pool descriptor; enables "d20 flow with d100 values" |
| Comparison / outcome-tiering | **Mostly, as declarative config** | direction (under/over/count) + compare-target + tier boundaries/labels. Percentile, d20-degrees, pools are three config files *if* you resist per-system procedural escape hatches |
| Adjudication flow | **No — fixed spine, and you want it fixed** | intent → difficulty → roll → tier → narrate → commit. Systems fill slots, don't rewrite flow |

Two leaks where "trivially dynamic" stops:
- **Difficulty-setting resists pure data** — it's a per-check contextual judgment. Let the *system
  spec* declare a difficulty **strategy** (fixed-in-stat / table / director-judgment) rather than
  making difficulty itself data. Percentile's "difficulty mostly lives in the stat" is an
  operational advantage in an automated system.
- **Narration prompt is templated, not hardcoded or fully dynamic** — ships per-system via the
  Solid/Liquid template layer; tier labels flow from the comparison spec into template variables.

### First three systems (ordered by fit, not popularity)

Rationale: you have an automated roller and a neutral degree-of-success interpreter, so spend the
saved human-ergonomics budget on **granularity**.

1. **Percentile / d100 (BRP/CoC lineage)** — skill value *is* the character quality as a 1–100
   number (no abstraction layer); degrees baked in; roll-under folds difficulty into the stat
   (least Director difficulty-setting — an operational win). Con: flat distribution, no
   competence curve.
2. **Dice-pool / count-successes (Year Zero / WoD lineage)** — success is a literal count (cleanest
   fit for degree-as-quantity); partial-success/complications pair with "rejection is a beat".
   Con: two stats per check (attribute + skill), less intuitive curves.
3. **d20-with-degrees (PF2e-style crit tiers)** — argued *against* plain d20 (coarse, binary), but
   the +10/−10 degree variant reclaims most of it and buys **familiarity** (huge adoption value).
   Con: compressed growth range, flat distribution with *less* granularity.

The three deliberately span the design space (roll-under-single-number / count-successes-two-
numbers / roll-over-vs-DC) to stress-test the resolution interface. If it abstracts over these
three, it abstracts over Fate/PbtA later.

---

## P6. Style / reference material (settled direction + legal line)

### The clean split

- **Style-transfer at inference beats fine-tuning** on every axis that matters here: zero training
  cost, instant iteration, steerable, and *legible* (an editable spec, not an opaque adapter).
  Style is a **context problem, not a weights problem** — condition generation on an authored
  style spec in the stable prefix, like world rules.
- **Style is not copyrightable.** Writing *in the manner of* something, without reproducing its
  expression, is on much safer ground than reproducing its world.

### The legal line (⚠ get advice before crossing)

- The favorable "AI training is fair use" rulings are about **training**, are unsettled, and — key
  point — **do not shield outputs**. Generating stories with named, protected characters/settings
  is a **derivative-works** question, which is close to the core of what copyright restricts, and
  the training cases give no cover there.
- **Intent and design matter.** A general tool that *can* write many things is a very different
  legal position from a *designed, marketed* "Franchise X campaign generator." Stay on the tool
  side.

### What to build vs. defer

- **Ship:** user-authored style specs; hand-authored genre/register presets that reference no
  protected source; style as a **first-class ownable/forkable/publishable object**. This is the
  differentiator and it's clean — it's about *how* things are written, not *whose world*.
- **Defer (legal-gated, Tier 3):** **ingestion** ("paste text → style object"). Extracting *style*
  is defensible, but the feature invites copyrighted text into your systems and does analysis on
  it — an ingestion question needing advice. Do not let it become a content/setting-extraction
  path.
- **Don't build:** a franchise/character affordance as a designed feature. Users will try to make
  fanfic (unpreventable, like a word processor); there's a bright line between "tool can be used
  for many things" and "we built the Star Wars generator."
- **Demo settings:** an original setting written *in a register you admire* is fine; a port of a
  specific copyrighted *world* is derivative. (Applies to any real short story used as a reference
  setting.)

---

## P7. Kids-with-guardians mode (separate product; far out)

A near-**inversion** of v1's architecture, gated on **legal advice + a safety-provider integration
+ a distinct compliance data layer**.

- App-wide 18+ becomes conditional; needs **COPPA-grade** verifiable parental consent and data
  minimization for minors (a *higher* bar than v1's data handling).
- Needs parent-moderation surfaces and **explicit-content filtering v1 deliberately doesn't have**.
- **Provider-swap is the pragmatic core:** rather than build explicit-content classification and
  own that liability, route kids-mode campaigns to a provider whose safety layer handles it and
  whose terms cover it — one of the few cases where the *rejected* providers become an asset.
- Forks v1's **data-handling** regime (minors' data is a different legal regime; can't share the
  permissive posture). A failed kids' safety story fails badly and publicly — the personal-
  responsibility weight here is real; deliberately not soon.

---

## P8. Organizations / enterprise (separate product; customer-gated)

Necessary **if** the professional class is real; it's the "third party covers tokens for a group"
piece that lets businesses transact with you.

### Why it's a separate product

It introduces a **second ownership-and-consent root** between user and content, and v1's entire
model assumes that root doesn't exist. Org changes the *answers* to questions v1 already answered:
who sees org content, who consents to the analysis opt-out, who admin-pierce reaches first on a
report, whose deletion right governs when an employee leaves. Enterprise buyers *require* the org
answer to all of these.

- Contrast with kids mode: **kids mode forks data-*handling*; org mode forks data-*ownership*.**
  Different seams, both fork §C of the backend.

### The one cheap v1 hygiene item (see §P2) — ✅ done

**Owner is now an indirection, not a hardcoded `user_id`.** `Polyphony.Owner` (`{type, id}`) +
`library_entries.owner_type` are in place; ownership is always a user in v1 but shaped to become
polymorphic. Org support is now "add an `:org` owner type + a permission layer," not a schema-wide
migration.

### The enterprise suite (build with the first real customer, not speculatively)

SAML/SSO, SCIM provisioning, role-based permissioning within the org, org-level token
administration (per-seat caps + increase-request flows), org-visible audit logs, consolidated
billing, configurable data-residency/retention. Half of this is shaped by the first buyer's
procurement/security review, so it's **co-designed with that customer** — building it ahead of a
contract is guessing at a requirements list the buyer will hand you.

### The dual-membership footgun

A user in **both** a personal capacity and an org seat needs those kept cleanly separate — personal
content mustn't become org-visible, org work mustn't be walkable-away, and the UI must make "which
hat am I wearing" unambiguous. This is where naive org implementations leak, and it's another
argument for clean owner-indirection: personal vs. org content differ *only* by owner, so a proper
indirection makes the separation structural rather than a scatter of checks.

---

## P9. Cross-cutting notes carried from the design conversation

- **Retain less** as a standing principle (from the E2EE discussion). The cheapest risk reduction
  isn't encryption — it's not holding data you don't need. Helps every risk category at once
  (breach, subpoena, moderation load, privacy obligations) and costs nothing to reason about
  early. E2EE itself was **considered and set aside**: the transmission path can't be E2EE (the
  provider needs plaintext to infer), it fights your own moderation model (report-pierces needs
  operator access), it creates a brutal account-recovery cliff, and it likely doesn't reduce
  *content* liability (which runs on provider status + responsiveness, not readability). Pursue
  contractual no-logging at the provider + encrypted-at-rest-with-operator-access instead.
- **Debug logging is the E2EE-adjacent early quirk to watch.** From-nothing debugging wants
  verbose logging, and content-bearing debug logs are exactly the sensitive payload. Make verbosity
  a **runtime level** (not commented-out code), route content-bearing logs on a **separate
  tag/channel** from operational logs, and give even debug logs a **retention window** from day
  one. Verbose-but-ephemeral is fine; durable-and-forgotten is the trap.
- **The moderation surface is the real content-liability protection** — more than any storage
  choice — because the favorable intermediary-liability regime turns on responsiveness to reports.
  Over-invest here relative to its apparent glamour.

---

## P10. One-screen summary

- **Sort everything by:** does it add an LLM pass (→ post-monetization), is it latent (→ cheap
  now), does it gate other things (→ pull forward).
- **Pre-monetization:** cheap/latent items + style-as-object + the pass-free harness. Iteration is
  the prerequisite for stickiness, and stickiness is the prerequisite for anyone paying.
- **Two wide gates:** moderation (everything social) and BYO-endpoint (pass-heavy features +
  multiplayer cost tail).
- **Monetization:** recurring token bucket (cost alignment) + monthly multiplayer slot
  (pricing surface); 30-day multiplayer trial, not a permanent free game; BYO/PAYG for the heavy
  tail; "active = recently generated" idle-transition serving engagement + cost + billing-lapse.
- **Two separate products on the engine:** kids mode (forks data-handling), org/enterprise (forks
  data-ownership). The only v1 hygiene either needs is **owner-as-indirection**. (A third, later
  separate product — **novelization**, §P11 — forks the *output*, not a data regime.)
- **Biggest single v1 ask from this doc:** preserve the seams in §P2 — especially owner-indirection
  — so none of the above is a rewrite.

---

## P11. Novelization / export-to-novel (separate product; late)

Take a **published campaign** and package it as a **novel** — a genuinely new *output* product on
the same engine, and a new monetization stream (self-publishing to Amazon/KDP and the like). Late;
not yet designed. Captured here so the design notes aren't lost.

The pipeline is much more than a transcript dump:

- **Cut low-progress turns.** The round-robin beat pattern produces character turns that don't
  advance the scene much; novelization revises scenes to **drop or compress** them.
- **Reorganize into prose.** Reflow the turn-by-turn structure into **paragraphs** — text
  organization *outside* the round-robin pattern — with **light editing** so it reads as smooth
  prose, not logged moves.
- **Revision propagation (the hard part).** Novelization needs **revision inputs**: change an
  event in one place and every reference to it elsewhere must change too. That means **walking the
  character and world arcs** so narrative and causality stay consistent across the whole book —
  the same **supersede-and-recommit + canonical-read + arc** machinery v1 already has, applied at
  book scope rather than beat scope. *Don't rebuild these primitives — reuse them.*

*Why it fits Tier 4+:* own pipeline, own review surface, independently monetizable, and it leans
entirely on existing engine primitives. *Open questions:* how much editing is automated vs.
author-in-the-loop; **POV/narrator** handling (does the book narrate from one character's filtered
projection, or omniscient? — this is the visibility model resurfacing as a craft choice);
chapter/scene segmentation; export format (EPUB/DOCX) and the KDP path; and rights/attribution for
forked or collaborative campaigns before anything is sold.
