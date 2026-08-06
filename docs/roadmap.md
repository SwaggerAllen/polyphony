# Polyphony — Roadmap

**What's left.** References: the design brief (§n), the **backend delta** (§A/§B/§C), and
the **frontend spec** (FS Vn). See `architecture.md` for how the shipped parts work, and
`backend-backlog.md` for the concrete engineering worklist this schedule draws from.

**What's shipped is not here.** §15's build order, amendments **A1–A5**, additions
**B1–B9**, all of **§C**, the one-pass FE/BE parity audit and the first-cut LiveView's
view inventory have moved to **`completed-roadmap.md`** with their detail intact. This
file had grown to five hundred lines of which four hundred were finished work, which is
how an open item goes unread. Each section below keeps a one-line pointer where something
was moved.

In one line: the whole domain, auth/identity/moderation/costs/export/scene-control, and
the first-cut LiveView are built and green offline; what remains is the §B10–B12 design
work, the A6 generation-review panel, and the frontend rebuild.

---

## §A — Amendments (revise shipped behavior)

**A1–A5 are done** — multiple yields per beat, pending drafts, boundaries × arc, editing,
and the three nested content layers. Detail in `completed-roadmap.md`.

- **A6 — Authoring generations get a review panel; some of them get a gate.**
  **Planned, not urgent** (`backend-backlog.md` §2.18). Every ✦ control writes straight into
  the field and autosave keeps it, so there is no moment where the author reads what came
  back and either steers it or refuses it. Play already works the other way twice over — a
  generated *turn* is a draft you accept or discard (A2), and the composer's Expand takes a
  **steer** (`Suggest.variants/1`) — while `Autofill` has no way to say what was wrong with
  the last answer. Arc has carried the full pattern since §3.0: a proposal, a "Because" line,
  and an accept / reject / edit gate. None of that asymmetry is a decision anyone made.
  - The **panel is unconditional** — seeing the result and regenerating with a comment is
    worth having on every generation, including the ones nobody needs to approve.
  - The **gate is conditional** on the generation overwriting authored work: filling a blank
    applies immediately, replacing three written paragraphs waits. Splitting the two is what
    stops this becoming a confirm-dialog the author learns to click through.
  - Where nothing needs approving, the accept control must read as *already applied* rather
    than *blocked* — the kit's `.btn-off` exists for the inert state, but the wording is the
    part that matters. Decide it in the mocks.
  - **Carries the fact flags with it.** `Autofill.suggest_facts/2` already asks for `core`
    and `concealed` per fact, with the distinction spelled out — *core is whether **she**
    carries it every turn, concealed is who **else** has it; a woman can have a secret she
    never thinks about*. But `generate_all/4` declares `facts` as `:lines`, a bare newline
    list with nowhere to put a flag, so both the sheet editor's `put_generated_facts/2` and
    Quick Build's `to_character_sheet/2` build `%Fact{statement: …}` on the struct defaults:
    **everything public, nothing core**. The consequence is a quick-built cast with zero
    concealed facts — `Visibility` working perfectly with nothing to act on, on the fastest
    path to a cast and therefore the likeliest first experience of the product.
    Quick Build's comment states the reasoning it was built on: *"concealment is an
    authoring decision, and a build that guessed at it would be deciding what a character
    may know on the author's behalf."* Right in principle, and shipping everything public
    is also a decision made on their behalf — just an invisible one. Three things point the
    other way now:
    - the **risk is asymmetric**. A wrongly-concealed fact makes a character know too
      little, which is the direction rule 3's default-deny already prefers and which the
      author can flip. A wrongly-public one spills something that cannot be un-spilled once
      it has been played into a scene.
    - **`core` is not the same kind of call.** It is a context-budget knob, not a visibility
      guarantee: over-marking costs tokens and dilutes conditioning, and can break nothing.
    - `Group` already goes the other way and has to. Quick Build's group phase asks for
      `concealed` on group facts, because `Group.secrets/1` exists, the design's own row
      reads *"6 members · 2 secrets"*, and a group whose facts are all public is a label
      rather than a membership.

    So: change `generate_all`'s `facts` to the structured shape `suggest_facts` already
    returns and carry the flags through both callers — with one hard limit, that
    **`audience` stays empty**. Guessing *who else* knows a secret is the part that is
    genuinely the author's and the part where a wrong guess actively leaks; concealed-from-
    everyone is the safe default and the one the picker already starts from.

    It lands **with** the review panel rather than before it, and that is the whole reason
    it is filed here. Auto-categorising on its own does not fix the real complaint — that
    an author never realises a decision was made — it only moves the invisible decision
    from "all public" to "the model chose". Marked-up facts arriving in a panel that says
    *these three came back secret* is the version where the author sees the call and can
    overrule it.

---

## §B — Additions (net-new surfaces)

**B1–B9 are done** — ownership/publish, auth/identity/consent, admin/moderation, the
notification path, cost caps + per-user accounting, export, manual scene control +
Continue **and Auto**, character stubs, and soft-delete. Detail in
`completed-roadmap.md`, including the UI remainders each one deferred.

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

## §C — Cross-cutting data-handling

✅ **Done (backend).** The reactive/proactive access split, opt-outs enforced in queries,
retention and deletion windows, the admin audit log and consent versioning. Detail in
`completed-roadmap.md`. Backups and legal holds remain ops concerns.

---

## Frontend redesign & design-kit fidelity 🔨 **In progress**

The first-cut LiveView is being replaced screen by screen from `ux/` (the mocks plus the
`polyphony-kit.css`/`polyphony-kit.html` component kit). The **foundation is done** — the
kit's tokens and classes are *derived* from `ux/` by `mix kit.port` rather than
hand-copied, its markup lives in `PolyphonyWeb.Kit` as function components, every
component has a `/storybook` page, and the play view is id-native. Detail for all three in
`completed-roadmap.md`.

**Every screen is now ported**: play, campaign hub, sheet editor, world bible, group
editor, arc review, library, browse, settings, admin, the auth screens, the landing page
and the app shell. The first-cut design system was **deleted** rather than kept
compatible, on the standing call that the app has no users until the rebuild lands.

What that leaves, each needing its own design surface or backend wiring rather than a
port:

- The **audience picker** (`ux/polyphony-audience-picker.html`) as an explicit "say it to"
  control on the composer. The `(whisper to NAME: …)` syntax carries it meanwhile, and the
  picker itself is built — it just isn't on the composer.
- The redesigned **Introductions panel + character picker**.
- The campaign's **Groups tab**. `Polyphony.Groups` and the group editor both exist; the
  tab that makes one from the campaign hub does not.
- Whatever the screens turn out to need once they are used in anger — this section is the
  place for that, not a list of ports.

---

## Still one-sided, and deliberately so

What the parity audit (`completed-roadmap.md`) left open after everything wireable was
wired. The standing rule it exists to enforce: a new event type, context function, or
`Costs`/retrieval/generation seam is not done when its test passes — it is done when
something on the live path calls it.

- **Bare "branch from here."** `Fork.fork/3` is reachable only through an edit that says
  it changed what happened. A scene branches correctly; you just can't ask for one.
- **Export / download** (§B6). Built in the domain, no UI hook.
- **Failed turns requeue to tail** (§1.4) — deferred by decision; a failed turn is
  retried in place.
- **Deferred FS views** — V2 Scene Index & Branch Navigator, V3 Character Inspector,
  V7 Location Graph, and the V10.1 prompt-template editor (`solid`/sandboxed Liquid).
- **UI remainders from §B** — B5's resume/raise-cap surface, B9's delete-confirmation
  flow, and B9's scheduled recovery-window auto-purge job.

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

Steps 1–7 of the original order — §A, B1–B9 with §C alongside, the LiveView, the deploy —
are done and recorded in `completed-roadmap.md`. What's left, in the order it should
happen:

1. **The frontend rebuild.** The screens, in `ux/README.md`'s order, on the backend
   prerequisites `backend-backlog.md` tracks as the immediate milestone. This is the
   critical path: the app has no users until it lands.
2. **A6 — generation review.** Deliberately last of the amendments: it changes a flow that
   works today, and its value is quality-of-authoring rather than capability. The panel half
   (steer and regenerate) stands alone and could ship first; the gate half wants real use
   behind it, since which generations overwrite enough to be worth stopping is a judgement
   nobody can make from the outside. The **fact-flag pass-through** rides with the panel:
   it is a small change on its own and a bad one without somewhere to show what the model
   decided.
3. **B11 → B10 → B12**, in that order and for one reason each: locations have to be
   first-class before a location-scoped trigger has anywhere to fire (§B10), and the World
   actor is the natural owner of world-scope triggers once they exist (§B12), which is why
   its own note sequences it after the locations surface.

---

## Beyond v1

The post-v1 horizon — monetization shape, TTRPG resolution, kids/org products, style material,
and the ordering logic behind it all — lived here as "Part II" and now has its own home:
**`decisions.md`**. That's the *forward rationale*; this file stays the near-term *schedule*.
The concrete engineering worklist the schedule draws from is **`backend-backlog.md`**. See
`docs/README.md` for how the docs divide up.
