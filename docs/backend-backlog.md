# Polyphony — Backend Backlog

**What this file is.** The standing engineering worklist: concrete backend work that isn't
built yet, each item saying what's needed, why, and whether it's **wiring** (code exists,
nothing calls it), **change** (existing code needs different semantics), or **new**. It began
as the frontend design's list of dependencies (the UX pass, `ux/`), which is why so many items
cite a designed screen — but it's no longer frontend-specific: it's the single home for
"backend work we've decided we want and know the shape of."

**How it differs from its neighbours.** `decisions.md` is the *strategy* and *why* behind the
post-v1 horizon; this file is the *worklist* — the tractable, shaped tasks that serve it.
`roadmap.md` is the *schedule* that pulls from this list. `backend-capabilities.md` is the
*catalog* of what already exists (and its gap register); this file is what to do about the gaps.
When an item here is designed and dispositioned, it's ready to be scheduled. See `docs/README.md`
for the full boundary map.

**Cross-references.** `§n` markers point at the **Backend Capability Catalog**
(`backend-capabilities.md`) — the numbered survey of existing capabilities.

---

## Immediate milestone — what the current design needs to function

Most of this file is a standing backlog to schedule against feedback. This slice is different:
it's the set that **gates the shipped frontend design**, so it's the near-term target.

**Shipped** (detail in `completed-roadmap.md`): §5.1 scene-close fan-out; §1.1–1.3 branching
family (found already complete); §1.5/§1.6 draft accept-discard + pass-turn (backend);
§1.7 per-viewer failures; §2.3 scene premise & location; §4b.1/§4b.2 account framing.

**Still open in the milestone:**

- **§1.4 — failed-turn requeue-to-tail.** *Deferred by decision.* The beat already carries on
  and closes on a terminal failure (no stall); the requeue-to-tail-once refinement is an
  optional resilience nicety, folded into the config-spike roadmap item (`decisions.md §P12`).
- **§2.8 — world arc.** The one substantial feature left: durable world-change entries
  (proposed→canon, parallel to character arc) + a propagation rule so off-screen characters
  learn world facts. Sits on §5.1 (now wired). In planning.

Everything below §2.3/§2.8 in the section numbering — the rest of §2, §3's publishing cluster,
§4 reporting, §6 deferred — is the standing backlog: real, shaped, but scheduled against user
feedback rather than blocking the current design.

---

## 1 · Blocking the current design

### 1.1 Fork wiring — `Fork.fork/3` · ✅ **Shipped** (found already complete)
Fork truncates at the cut beat and opens live there; `Reroll`/`Edit` are branch-relative for
free because a fork is a separate stream. "Branch from beat N" UI is frontend, deferred. See
`completed-roadmap.md`.

### 1.2 Edit with tail invalidation — `Edit.edit/6` `:invalid` · ✅ **Shipped** (found already built)
`Edit.edit/6` complete (`:valid` any beat, `:invalid` forks); no branch-relative guard needed.
Caller (frontend) deferred. See `completed-roadmap.md`.

### 1.3 Lineage records the cut beat and nothing else — `ReadModels.SceneFork` · ✅ **Shipped**
`SceneFork` records `fork_beat` and nothing else, as prescribed. The optional read-time
"identical-so-far / changed" comparison is a small helper to add when the branch-navigator UI
wants it — not a blocker. See `completed-roadmap.md`.

### 1.4 Failed turns requeue to the end of the beat · **change** — *deferred*
The stall this warns about doesn't exist: a terminal failure records `PacketFailed`, the walk
treats it as terminal, and the beat carries on and closes (*fail → skipped → carry on*). The
unbuilt part is the softer **requeue-to-tail-once** (retry the slot at the end of the beat
before giving up, with a retry count) — a resilience refinement with a narrative cost (a
requeued turn conditions on turns that reacted to its absence). **Folded into the config-spike
roadmap item** (`decisions.md §P12`): turn-order and failure behaviour want to be configurable
per scene/beat (writers who don't want reordering; solo players who just want play not to stop;
multiplayer retry/fairness once dice land), so requeue-to-tail becomes one policy among several
rather than a hardcoded change.

### 1.5 Draft accept / discard · ✅ **Shipped (backend)**
`BeatDriver.accept_draft/2` and `discard_draft/2` complete and tested; the approve/discard card
is frontend, deferred. See `completed-roadmap.md`.

### 1.6 Pass turn · ✅ **Shipped (backend)**
`BeatDriver.pass_turn/4` complete; the composer/quick-sheet entry points are frontend, deferred.
See `completed-roadmap.md`.

### 1.7 Failures scoped per viewer · **change** — ✅ **Shipped**
Turn failures now reach the failed character's own viewer topic (+ omniscient); author-facing
failures stay omniscient-only; `PlayLive` loads per-viewer. See `completed-roadmap.md`.

---

## 2 · New — not modelled yet

### 2.1 Concealed and partial presence · **new**
There is currently no way for a character to be in a scene but hidden, or known to only
some of the people present. `Membership` is a half-open interval and `visible_to?/3` judges
membership at the beat (§1) — presence is binary and symmetric.

Wanted: presence that is per-observer. Someone in the rafters is a member for beat purposes
(they can act, they can hear) but is not known to the other members until they do something
that reveals them.

This is a real feature, not a UI concern, and it's the prerequisite for 2.2.

### 2.2 Turn-order visibility filtering · **new** *(depends on 2.1)*
`TurnOrderDeclared` is user-and-system visibility (§1). Any per-character surface that shows
who is due to act leaks the room — including anyone concealed under 2.1.

Deferred for now by decision: the current design shows the beat as a plain rule with no
roster, and the transcript tail names only the character whose turn is live. Revisit
together with 2.1.

### 2.3 Scene premise and location as authored fields · **new** — ✅ **Shipped (backend)**
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

### 2.4 Reorder pending turns within a beat · **new**
There is no way to change `TurnOrderDeclared` once a beat is underway (§1). The design makes
the beat tracker the only object representing turn order, which makes dragging a slot the
natural gesture — and it removes the need for an out-of-turn write path, since "act now"
becomes "move to the front, then act in turn." `seq` stays meaningful.

Two constraints the design assumes:

- **Only the pending tail is movable.** Slots that already acted are events; they happened.
  Freeze them.
- **Within a beat only.** Moving a turn from beat 4 into beat 3 is not a reorder, it is a
  rewrite of history — that is a branch (1.1). Keep the two words apart in the API so the
  distinction survives contact with the UI.

### 2.5 Cast tiers — context residency, separate from sheet status · **new**

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

### 2.5b Attaching a world copies it · **change**

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

### 2.5c Finishing a campaign · **new**

Distinct from archiving. **Archived** = out of the library, reversible, no semantic meaning.
**Finished** = deliberately concluded: closes any open scene through the normal path, marks
the campaign as a completed whole, and is the precondition for another campaign naming it as
a prequel (3.4). Reversible, but it's a statement rather than filing.

### 2.6 Character picker for introductions · **wiring**

The Director may only propose from what it knows about — the campaign's cast and its
off-screen stubs. The GM's picker reaches the whole campaign roster, including walk-ons the
Director wouldn't think to suggest.

- Same search component as the library's character list (§7) — search, tier filter, rows.
  Build once, use in both.
- **Campaign-scoped.** Characters do not cross campaigns. See 2.7.

### 2.7 Characters do not cross campaigns · **scope decision**

*Recorded so nobody builds it speculatively.* `instantiate_character` (§7) stays unwired.

Two reasons, and the second is the one that decides it:

- **A sheet is written against a world.** Appearance, voice, backstory and facts all lean on
  setting. A character lifted into a different world is subtly broken in ways that read as bad
  writing rather than as a bug, so cross-world import is out on its own merits.
- **The people who want import want the part that doesn't port.** Nobody moves a character for
  the prose — they can retype that. They want the arc and the relationships, which are exactly
  what's entangled with the source campaign's history. Delivering the cheap version (sheet
  only, arc dropped) satisfies almost nobody while looking like the feature exists.

**Get real users before designing this.** The assumption above is a guess about what people
want out of it, and it's worth finding out rather than paying for a merge engine up front.

If it does come back, the tractable form is setup-time only: a campaign declares an earlier
campaign as its prequel, and imports at setup while the target world arc is still empty — a
copy, not a merge. Mid-campaign import is a merge of two divergent canon histories and should
stay out of scope regardless.

### 2.8 World arc — durable world change, and who knows about it · **new** — ✅ **Shipped (A–D)**
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

### 2.9 Multiplayer access grants · **new**
Deferred. Multiplayer is currently a conceptual constraint on a single-player UI — whoever
has access to a character's perspective may change that character's settings. When real
multiplayer lands, the grant model ("who may see and act as whom") belongs in campaign
settings, and control-mode permission follows from it.

**Scene casting is deliberately GM-dictated for now**, and this is not a placeholder — it is
the correct single-player behaviour. When invitations arrive, accept/decline becomes a state
between "GM submitted" and "scene opens," carried on the existing cast row rather than a new
surface. Same for mid-scene entrances: admitting a Director proposal is immediate today, and
gains a pending state later without changing shape.

### 2.10 Auto-advance / multi-beat pacing control · **new (surface) + wiring**
Depth-cap chaining exists in `BeatPolicy`; Continue is hardwired to single-beat yield
(§2, §12). The design puts an auto-advance setting in the play settings sheet — scene-scoped,
with a stop condition. Needs a control path into the existing policy.

---

## 3 · Publishing, continuity & knowledge

A cluster that emerged together and only makes sense together: how a campaign gets shared,
how one campaign builds on another, and who is allowed to know what.

### 3.1 Publication is a set of viewer perspectives · **new**

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

### 3.0 Arc review gates the next scene · **new** — ✅ **Shipped (MVP)**

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

### 3.0b Group arc, and how it reaches members · **new**

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

### 3.1b Limited omniscient — the published reading mode · **new**

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

### 3.1c Publication is two independent settings · **change**

*Supersedes the four-rung ladder in an earlier draft, which conflated two unrelated decisions.*

- **How it's read** — a content decision: which perspectives are offered (spectator, limited
  omniscient, named characters). Any combination, including leaving spectator out.
- **Forkable** — a permission decision: one checkbox. Character sheets come with it, because a fork
  must be able to continue the story and can't from prose alone. Not a separate rung.

Consequence: **characters are not publishable on their own.** They travel only inside a fork, since
a character lifted out of their campaign has no history and knows nobody — which is the same reason
cross-campaign import is out of scope (2.7). Browse lists stories and worlds, not people.

### 3.1c-ii Unreadable scenes must be detectable at publish time · **new**

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

### 3.1d Group copies by their root · **new**

Every campaign copies its world (2.5b) and every fork copies everything, so within a year there are
a dozen artifacts called Saltmarch. Flat lists become unusable.

- Needs a **root identity** on derived artifacts, not just a `derived_from` parent pointer — walking
  the chain per row to group a list is the wrong shape.
- **Library groups versions by campaign**; one row that expands, not four rows with the same name.
- **Browse groups forks by author**, because three forks share a title until someone renames one.
- `derived_from` is already stored on every derived entry and has never been displayed. Show it: a
  reader should always be able to walk back to where something started.

### 3.1e Reading position on a published campaign · **new**

A published campaign someone is reading isn't theirs, may not be forkable, and can be unpublished
underneath them — so it can't live under their campaigns, and it needs its own shelf.

Bookmark needs **scene, beat and perspective**, since perspective is part of where you were. Keep
the bookmark when a campaign is unpublished rather than dropping it; it may come back.

### 3.2 View-as outside the play screen · **new**

Perspectives now matter everywhere, so `visible_to?/3` has to be reachable from surfaces that
have never needed it: the campaign hub, the cast list, scene summaries, the world bible, and
whatever the published reading view turns out to be.

- **You author omniscient and preview as a character.** Preview is explicitly marked and
  **read-only** — editing a sheet while seeing a filtered version of it is how someone deletes
  something they couldn't see.
- **An unassigned viewer is a real state**, not an error: a multiplayer participant before
  character assignment, and any reader outside a granted perspective. Default-deny already
  gives the right answer — they see nothing.
- **Open question: is there a spectator projection?** Speech and action visible, thoughts and
  whispers not — a camera in the room rather than a head. It's a genuinely different
  projection from both omniscient and any character, and it may be what a published campaign
  wants when the author grants nobody's interiority. Worth deciding before 3.1 ships.

### 3.3 Selective starting knowledge · **new**

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

### 3.4 Prequel is a subset-fork · **new**

*Supersedes an earlier reading of prequel as a mere continuity label.* Fork and prequel are
the same machinery over different subsets of state:

- **Fork** takes the whole timeline and continues **the same story** — every character, every
  arc, the transcript itself.
- **Prequel** takes the **world arc** plus **selected character arcs** as canon and starts a
  **new story**. It may share cast, or none at all.

Consequences:

- **Selecting a non-owned campaign as prequel is allowed**, because fork-then-declare is
  already legal and blocking direct selection is pure friction — the same argument that opened
  the world picker to published worlds.
- **But selecting one saves its snapshot into your library first.** Everything a campaign
  references, you own. The prequel can't then change or vanish underneath you.
- **Mid-campaign import from a declared prequel is allowed**, reversing the earlier position.
  It's cheap for a specific reason: the character isn't arriving from a foreign timeline, but
  from *this campaign's own declared past*. The prequel's world arc is already this campaign's
  starting canon, so there is nothing to merge — only the deltas since. Catch-up is the same
  operation as for any off-screen character (2.8): inject the world-arc entries they missed,
  let them react on screen.
- **Restricted to declared prequels.** Import from an arbitrary campaign remains out of scope
  (2.7) — that one is a merge, and this one isn't.

### 3.5 Save a non-owned artifact to your library · **wiring**

The acquisition primitive everything above leans on, and the sibling of
`instantiate_character` (§7). A reader on a public campaign, world or character can save it,
which copies it into their library with `derived_from` recorded.

Also the mechanism behind the two backdoors: choosing a published world from the campaign's
World tab, or a published campaign as a prequel, saves first and then attaches — so neither
picker ever attaches a remote artifact.

### 3.6 Ownership transfer · **new**

Independent of everything above, and useful on its own: a group's GM hands the campaign to
someone else between campaigns.

The campaign is the easy part. The complication is that its world and cast may be shared with
the previous owner's *other* campaigns, so a transfer probably has to **pin copies** of the
referenced artifacts rather than move the originals out from under them.

Note this also makes prequel work for a handed-over group without any loosening: once both
campaigns belong to the new GM, the same-owner reference is legal.

---

## 4 · Reporting — two different things

Regulatory compliance needs a report path anywhere a user can encounter content **another
person authored**. But a single "report" button collapses two unrelated flows, and merging
them is how the moderation queue fills with noise.

### 4.1 Report · **wiring**
Moderation, in the existing sense — `moderation.ex` (§9) has the full queue, take-down,
suspend, warn and audit path with **no user-facing intake anywhere**. Targets: published
campaigns, share links, browse entries, profiles, and in multiplayer, other players' turns.

Compliance test: **anywhere a user can encounter content published by another user, a report
path is reachable** — plus a catch-all route from help for anything those miss.

One detail the existing model already handles well: a report against a published campaign
targets the **frozen snapshot**, so a take-down removes the public copy without touching the
author's private original.

### 4.1b Take-down removes everything and audits descendants · **change**

A take-down is not an unlisting. It removes **the public snapshot and the author's own copy** —
they lose the campaign, not its listing. Their other campaigns are untouched.

**Forks descended from it go into a review lane, not down with it.** A fork may have diverged
twenty scenes past anything objectionable, so a cascade would destroy unrelated people's work.
Needs the root/lineage data from 3.1d to enumerate them.

The confirm should name what's destroyed in scenes and characters rather than "a campaign" — the
weight of the action should be visible at the moment of taking it.

### 4.1c Report history, both directions · **new**

Deciding whether a suspension is proportionate requires everything a person has been involved in:
reports **against** them with outcomes, and reports **they have made** with outcomes.

The second direction matters as much as the first — someone whose reports are nearly all dismissed
is using the report button as a weapon, and that's only visible if it's counted.

### 4.1d Suspension hides shared content, unlisted included · **change**

While a suspension is in force, everything the person has shared goes dark — **public and unlisted
both**, so share links stop resolving.

Unlisted is the load-bearing part: otherwise a suspended person registers again, opens their own
share link, and forks their way back in. Starting again should mean starting again. Nothing is
deleted, and lifting the suspension restores it all.

### 4.2 Flag · **new**
Model feedback: a generated turn in your own single-player scene came out wrong. There is
nobody to accuse — you own the campaign and a machine wrote it. Routing this into the
moderation queue would drown the actual reports.

Different destination, different copy, and **the only one single-player needs**. Cheap to add
to a turn's editorial row now.

---

## 4b · Accounts

### 4b.1 18+ is eligibility, not a content ceiling · **change** — ✅ **Shipped**
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

### 4b.2 There is no automated safety analysis to opt out of · **change** — ✅ **Shipped**
Removed the settings "opt out of proactive analysis" control (no automated analysis exists to
opt out of); the §C domain seam stays latent for when the feature lands (per campaign, per the
design). See `completed-roadmap.md`.

**What will be needed later**, and shouldn't be conflated with it: an opt-in for experimental
generation behaviour. That may belong **per campaign** rather than per account, since it changes
how a specific story plays, and it arrives alongside a profile page.

---

## 5 · Pre-existing, high priority

### 5.1 Scene-close fan-out is never triggered · **wiring** — ✅ **Done**
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

### 5.2 Character identity is a name, not a stable id · **change** — ⚠️ **latent data-corruption risk**
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
2b-emit + 3 (**the atomic remainder — must land together**). Resolve emitted **names → ids** and
   flip the mint in one change, because `addressed_to` may become ids only once viewers are ids
   too (otherwise whispers misroute — fail-*safe* under default-deny, i.e. a caught functional
   bug, never a leak). Precise sites, now mapped:
   - **Director cast → ids:** `run_beat.ex:164` (`resolved.cast` names) before `declare_turn_order`.
   - **Packet `addressed_to` → ids** at the packet-production points before `CommitPacket`:
     generation (`generate_packet`), the composer (`play_live`), and edit (`edit.ex`).
   - **Mint flip:** `campaign_live` `EnterCharacter{character_id: lib_id}` + seed by id.
   - **`play_live` viewer overhaul:** the viewer, roster `<option>` values, `speaker`, and whisper
     target parsing move from names to ids (display stays names). This is the largest single piece.
   - **Data clear:** reset dev/prod event streams + campaign `scenes` lists (clean-slate — no
     backfill).
   - **Tests:** dedicated id-path whisper routing + rename-safety (whisper to a character, rename
     them, whisper still routes; a bystander still can't see it).
4. **Arc + gate by id.** `arc_entries.subject_id` = the id; scene gate / arc review drop the
   name-resolution dance.
5. **Open the fields.** Make `name` (and other non-boundary scalars) freely editable + arc-
   overridable, now that identity is stable.

---

## 6 · Deferred, but the design leaves room

- **Enter / exit as a first-class move type.** `CharacterEntered`/`CharacterExited` are
  visible to members at the beat but have no rendering treatment; today they'd land as
  unstyled world events. A player should feel someone arrive.
- **Whisper recipients as structured data.** The composer currently parses
  `(whisper to NAME: …)` via `SayParser`. The design adds a recipient chip; the underlying
  move wants an explicit addressee list rather than a parsed one, especially once a second
  human is typing.
- **Pronouns as a character field.** Currently absent from `CharacterSheet` (§4). Needed in two
  places: interface copy written about the character (*what she won't do*, *if she's pushed*), and
  every generation call, which should be told rather than inferring from a name.
- **Reading preferences persistence.** Typeface, size and line spacing are per-user and
  per-device, scoped to the transcript. Could live client-side; noting it so it doesn't get
  modelled as campaign state by accident.

---

## 7 · Confirmed non-asks

Things the design intentionally does **not** need, so they don't get built speculatively:

- **No turn-level fork control.** Superseded by 1.1 + 1.2.
- **No out-of-turn write path, and no composer in the omniscient view.** To write a
  character you switch to their perspective — which is also the correct authoring context,
  since writing Wren while reading the omniscient transcript is how Wren ends up reacting to
  something she cannot know. "Act now" is 2.4 (reorder), not a special write.
- **No cost data in the player register.** Per-campaign spend and caps are author surfaces only.
- **No occlusion markers.** Nothing indicates that something was hidden — a filtered scene is
  simply a shorter scene. No placeholder rows, no locks, no dimming.
- **No per-artifact privacy inside a campaign.** Publication is one campaign-level decision
  (3.1). Nobody should ever set visibility on an individual walk-on.
- **No "don't fork this" flag.** Unenforceable on visible material. Forkability is the top
  rung of publication scope, not an orthogonal switch (3.1).
- **No third knowledge state.** Knows or doesn't. A false belief is a fact about the believer
  (3.3).
- **No generated scene titles.** The authored location is the heading — always present, can't
  be wrong, costs nothing.
