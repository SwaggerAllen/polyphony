# Polyphony — Completed Roadmap

Shipped work, moved here out of the active planning docs so those stay lean. When a
`backend-backlog.md` item (or a `roadmap.md`/`decisions.md` line) is done, its detail
lands here and the source file keeps at most a one-line pointer.

**What counts as done here.** Backend work whose code + tests have shipped. An item with
a *frontend* remainder (the backend seam is built but no UI calls it yet) still lands here
for the backend half — the UI work is tracked with the frontend redesign, not as an open
backend task. Read newest batch first.

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

## Housekeeping

### Documentation reconciliation
Split `roadmap.md` into the near-term schedule (`roadmap.md`) and post-v1 strategy
(`decisions.md`); moved the design's backend asks to `docs/backend-backlog.md` (renamed from
`ux/backend-asks.md`); archived the superseded mock-thread brief to `ux/archive/`; added
`docs/README.md` (the doc index + boundary map + "where new content goes"). CLAUDE.md now
describes the `ux/` design kit and the port-from-the-kit rule.
