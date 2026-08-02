# World Arc — design plan (backlog §2.8)

**Status: proposal for review, not yet built.** Once approved and shipped, the rationale distills
into `architecture.md`, the worklist closes in `completed-roadmap.md`, and this file goes away.

## The goal, and the one hard constraint

Today `WorldBible.starting_canon` is fixed and `WorldEventOccurred` is a *moment*, not a *fact* —
so there is nowhere for **"the moon fell out of the sky"** to live as durable, everyone-knows-this
canon, and no way for it to reach a character who was off-screen when it happened. World arc fixes
both: durable world-change entries discovered during play (proposed → canon on review), parallel to
character arc, feeding the **world half** of context assembly.

**The constraint that keeps it tractable (from the brief):** *facts are injected, feelings are
not.* An off-screen character gets the missed world **fact** dropped into their context — no
generation, no arc extrapolation, no silent sheet rewrite. How they *react* to news they missed is
**played on screen**, which is better fiction anyway. World arc never computes a character's
response; it only makes the fact available. And local facts stay dramatically ironic: a fact known
"in the port district first" must not appear in the context of a character who was never there.

## What already exists (mirror it)

The character-arc pipeline is the template, piece for piece:

| Character arc | File | World-arc analog |
|---|---|---|
| Extractor (per-character, **filtered** stream) | `scene_close/arc_extractor.ex` | Extractor over the **omniscient/unfiltered** stream, once per scene |
| Structured schema (`kind`, `sheet_field`, `statement`) | `scene_close/arc_schema.ex` | Parallel schema (`kind`, `statement`, `scope`, `location_id`) |
| Domain struct | `authoring/arc_entry.ex` | Reuse with `subject_type: "world"` |
| Read model `arc_entries` (`put`/`list_proposed`/`accept`) | `read_models/arc_entry.ex` | Same table + `subject_type` + two columns; add `list_canon` |
| Fold canon → sheet | `authoring/effective_sheet.ex` | `EffectiveWorldBible.apply/2` |
| Render into prompt (`Canon:` block) | `context.ex` `render_bible`, `scene_brief.ex` `render_world` | Render accreted world canon in the same block |
| Scene-close wiring | `scene_close.ex` `extract_participant` + `enqueue`/`run` | `extract_world` fanned out **once per scene** |
| Oban job | `jobs/extract_arc.ex` | `jobs/extract_world_arc.ex` |
| Review LiveView (accept-only) | `live/arc_review_live.ex` | Extend for world entries + reject/edit |
| Omniscient source stream | `read_models/scene_summary.ex` (`omniscient_key`) | Same |

**Two caveats this plan must confront (both surfaced by the investigation):**

1. **The character-arc accept→canon→generation loop is built but *not wired into the live path*.**
   `EffectiveSheet.apply` and the `:arc_entries` opt exist, but `play_live.ex` seeds the raw sheet
   and never applies canon arc; the only production consumer of canon arc is
   `Library.Snapshot.resolve_arc/3` (publishing). So "feed canon into generation" is unwired for
   *characters* too. World arc's whole value is that facts reach context — so this plan **wires the
   consumption path**, and since both arcs share the seam, it wires character arc at the same time.
2. **There is no reject/edit/retract anywhere** — review is accept-only (the `:retracted` status
   exists but nothing sets it). The design brief wants reject/edit. Net-new for both arcs.

## Design, layer by layer

### 1. The entry shape

Reuse the `arc_entries` table (its `subject_type` default `"character"` was clearly put there for
this). A world entry is:

- `subject_type: "world"`, `subject_id:` the **campaign_id** (world is copied per campaign, §2.5b,
  so world arc is campaign-scoped).
- `kind: :discovery | :revision` — same two kinds. *Discovery* = a newly-true world fact
  ("the moon fell"); *revision* = an update to existing canon ("the harbourmaster, alive in
  starting canon, is dead"). Both fold into the Canon block; a revision is just phrased as an
  update, read in beat order.
- `statement:` the fact, one sentence.
- `scope: :global | :local` — the propagation rule (new column, null for character rows).
- `location_id:` for `:local` entries, the place it's local to — defaulted from the scene's
  `SceneOpened.location_id` (new column, null for character rows and for global facts).
- `status:` `proposed → canon` (+ new `retracted` for reject), `beat`, `source_scene_id` — as today.

New columns on `arc_entries`: `scope :string`, `location_id :string` (both nullable). Character rows
leave them null; `sheet_field` is null on world rows. One migration.

### 2. Extraction — `SceneClose.WorldArcExtractor`

Mirror `ArcExtractor`, but over the **unfiltered** stream (the omniscient projection is the whole
log — no `Visibility.project`) since world facts are not anyone's private view. Prompt:

> "What is now durably TRUE of the **world** that wasn't before — a change to the setting or its
> canon that emerged in this scene? Not a character's private state, not a passing moment — a
> standing fact. For each, say whether it's **global** (everyone would come to know) or **local**
> to where it happened."

Schema (`WorldArcSchema`, mirroring `ArcSchema`): `{"entries":[{"kind","statement","scope"}]}`.
`location_id` is stamped from the scene (not the model's job), `source_scene_id`/`beat` stamped like
character arc. Returns `:proposed` entries. `response: :world_arc` structured-output tag.

### 3. Scene-close fan-out — one extra unit per scene

In `scene_close.ex`, alongside the per-participant `extract_participant`, add **one**
`extract_world(scene_id, opts)` — keyed off the whole stream, not per character. `enqueue/2` fans
out one `Jobs.ExtractWorldArc` per scene (next to the N `ExtractArc`); `run/2` runs it inline.
Cheap: +1 job per close. Failure classification identical (schema-invalid → cancel; transport →
retry). This rides §5.1, now wired.

### 4. Consumption — `EffectiveWorldBible` + wiring canon into context

The payoff. `EffectiveWorldBible.apply(%WorldBible{}, world_arc_entries) :: %WorldBible{}` folds
**canon** entries (status `:canon`, sorted by beat) into `starting_canon` — appending discoveries
and update-statements. Then both renderers (`context.ex render_bible`, `scene_brief.ex
render_world`) render the effective canon in the existing `Canon:` block; **no prompt-shape change**.

**Wiring (fixes caveat 1 for both arcs).** At scene-open seed (`play_live.ex`) and cold rebuild
(`Context.Rebuild`, `SceneBrief` rebuild):

- Load canon **character** arc for each cast member (`ArcEntry.list_canon(character_id)`, new) and
  apply `EffectiveSheet.apply` before `materialize` — so accepted character arc finally reaches
  generation.
- Load canon **world** arc for the campaign (`list_canon(campaign_id, subject_type: "world")`),
  apply `EffectiveWorldBible.apply`, pass the effective bible to `materialize`/`SceneBrief`.

This is the seam that was missing; wiring it is what turns arc review from decoration into effect.

### 5. Propagation — global always, local by scene location

Because we have `location_id` on scenes now (§2.3), the "better, location-scoped" version *is* the
MVP:

- **Global** canon → always in the world half of context, every character, every scene. This is
  how an off-screen character "catches up": the fact is simply present in their next scene's world
  bible, and they can react to it on screen.
- **Local** canon → included **only when the current scene's `location_id` matches** the entry's
  `location_id`. A character elsewhere never sees it — dramatic irony at the world level, for free.

What this deliberately does **not** do: track per-character world knowledge (who-was-there-carries-it).
That's character-knowledge territory (§3.3 selective knowledge / initial_knowledge), out of scope
here. World arc answers only "global or local-to-a-place," which is exactly the brief's minimum.

### 6. Review + reject/edit (caveat 2)

Extend `ArcReviewLive`: it already lists proposed character entries per subject; add a **World**
section querying `list_proposed(campaign_id, subject_type: "world")`, showing scope + location. Add
two events beyond `accept`:

- **reject** → sets `status: "retracted"` (the status already exists) so it leaves the queue and
  never reaches canon.
- **edit** → correct a `statement` (and toggle scope) before accepting — proposals are model output
  and often want a word changed. Small changeset on the read model.

Both apply to character and world entries (shared machinery). This is the brief's "arc review should
allow reject/edit, not just accept."

## Build order

Smallest-useful-first; each phase is independently shippable and tested.

- **Phase A — extract & store.** `WorldArcExtractor` + `WorldArcSchema` + the `arc_entries` columns
  + `Jobs.ExtractWorldArc` + fan-out in `scene_close.ex`. Proves world facts get *proposed* on close.
- **Phase B — consume.** `EffectiveWorldBible` + `list_canon` + wire canon (world **and** character)
  into the live seed + rebuild. This is the highest-value phase — it makes *both* arcs actually
  reach generation. Global propagation lands here.
- **Phase C — propagation refinement.** Local scoping by scene `location_id` in the context feed.
- **Phase D — review.** World section in `ArcReviewLive` + reject/edit for both arcs.

Recommended first slice: **A + B (global only)**. That delivers the real feature — durable world
facts that reach every character's context and let off-screen characters catch up on screen — with
propagation refinement (C) and the review polish (D) as fast follows.

## Open questions for you

1. **Storage: reuse `arc_entries` (recommended) vs. a separate `world_arc_entries` table?** Reuse
   honors the `subject_type` seam and shares the review/accept path, at the cost of two nullable
   columns character rows don't use. A separate table is cleaner-typed but duplicates the machinery.
2. **Scope of the caveat-1 fix.** Phase B wires *both* arcs into generation. That's the right fix,
   but it changes character behaviour too (accepted character arc starts affecting generation, which
   it doesn't today). Good — but it's a behaviour change to flag. OK to include, or keep world arc's
   wiring self-contained and leave character-arc wiring as its own follow-up?
3. **`kind` for world revisions.** MVP treats revisions as append-an-update-statement to the Canon
   block (no field-level targeting, since world canon is a list, not named fields). Fine, or do you
   want revisions to supersede a specific prior canon line?
4. **Gating (backlog §3.0).** "Arc review gates the next scene" / "world arc gates the whole
   campaign" is a *separate* item that sits on this. Out of scope for §2.8 itself — confirm we defer
   it.
