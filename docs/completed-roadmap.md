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

`app.css` is an ordered manifest — Tailwind, then `legacy.css` (the first-cut design
system), then the kit — and the order is load-bearing: every rule is a plain class selector,
so the kit wins the names it shares (`.row`, `.btn`, `.dim`, `.field`, `.dot`) and any
utility it overlaps with, which is the precedence the mocks have. **Unported screens are
expected to look wrong until they're ported** — an explicit author decision, since the app
has no users until the rebuild lands. The kit was briefly scoped to a `.fr` root so the two
systems could coexist; that bought compatibility nobody needed at the cost of a stylesheet
that no longer matched the design, and it's gone. `legacy.css` shrinks as screens port and
the last one takes the file.

### The kit's markup is `PolyphonyWeb.Kit`
The other half of the port: the kit's structural idioms as function components, lifted from
`ux/polyphony-kit.html` and the screen mocks — the perspective control, status strip,
transcript moves, marked list items, the info affordance, the nav primitives, and the
controls they sit in. Its one-class utilities (`.ttl`, `.mono`, `.dim`, `.lbl`) deliberately
stay as classes in markup, exactly as the mocks write them.

`PolyphonyWeb.Voice` holds the rule that makes voice colours useful: assigned by cast order,
never chosen, wrapping past eight, and emitted as `var(--vN)` so they resolve against
whichever register and theme the frame is in.

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
