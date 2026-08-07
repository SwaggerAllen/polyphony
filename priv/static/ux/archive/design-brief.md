> **Archived — superseded.** This is the brief that seeded the mock thread. The mocks in
> `ux/` are the design output; their decisions (some of which diverge from this brief — e.g.
> Quick Build is not a tab, Premise follows Cast) supersede it. The engineering follow-through
> lives in Linear (team `StrutCo`, project `Polyphony`). Kept for the reasoning, not for
> building.

# Polyphony — Design Brief (for the mock thread)

**Self-contained.** Everything a design session needs to mock the redesigned frontend
without reading the codebase. Pair it with the **Backend Capability Catalog** (separate
artifact — the list of every backend capability and whether the UI surfaces it).

---

## 0. What Polyphony is

An **event-sourced, multi-agent roleplay engine.** You author a **world**, a **cast of
characters**, and a **campaign**, then play out **scenes** — a mix of turns you write and
turns the AI generates for characters. A **Director** (world agent) paces each scene,
casts who acts, and brings new characters on.

**The one structural idea that shapes every screen:** *dramatic irony is data, not a
prompt.* Each character only ever sees a **filtered projection** of what happened —
another character's private thoughts, whispers they weren't part of, events before they
entered are structurally invisible to them. The author sees the **omniscient** view. The
play screen is therefore always **viewer-parameterized**: a "**View as**" selector
(Omniscient · or any character) that silently occludes what that viewer can't know. Design
the play view around this — it's the product's soul, not a toggle in a menu.

**Audience & platform:** solo authors and small groups on **phone first**, desktop second.
Server-rendered (Phoenix LiveView) — see §6 for what that means for mocks.

---

## 1. The information-architecture decisions (design to these)

These are settled directions for the rework. The mocks should embody them.

1. **The campaign is the hub. There is one "create" entry point: New Campaign.** Worlds
   and characters are *created or selected inside a campaign*, not from a top-level menu.
   (Today there are three separate create buttons — collapse them.)

2. **The campaign editor is an ordered, tabbed flow:**
   `Settings → (optional) Quick Build → World bible → Premise → Cast`
   - **Settings** — name, content ceiling (maturity), model/generation tuning.
   - **Quick Build** — optional one-shot: seed a world + N characters + premise and
     generate them all at once (a fast-start shortcut for the three tabs after it).
   - **World bible** — attach an existing world **or** create/generate one.
   - **Premise** — the campaign's pitch; AI can draft/expand it, grounded in world + cast.
   - **Cast** — attach existing characters **or** create/generate new ones; manage the roster.

3. **Worlds and characters are shareable across campaigns.** The World and Cast tabs let
   you *select existing* entities, so one world or character can belong to several
   campaigns. (Implication for mocks: pickers that list "your existing worlds/characters"
   alongside "create new".)

4. **Generation is always anchored to a campaign.** Because you author from inside a
   campaign, every AI generation can pull **campaign cast context** — the other characters
   in the campaign — for consistency (so three characters don't invent three different
   landlords for the same building). This especially matters on the **relationships**
   generation, which is its own AI call with room for that context. Design authoring
   screens knowing "the rest of the cast" is available context.

5. **Play stays viewer-parameterized** (see §0) — keep the "View as" selector central.

---

## 2. Domain glossary (use these nouns in the UI)

| Term | What it means to a user |
|---|---|
| **Campaign** | The hub: a world + a cast + a premise + its scenes. |
| **World bible** | The setting: name, setting, tone, rules, starting canon. |
| **Character (sheet)** | An authored persona: prose fields + facts + relationships + boundaries. |
| **Stub / pending character** | A placeholder character (a name + one-line role) that hasn't been fleshed out. Reads as "pending"; finalizes when you save it. |
| **Cast** | The characters in a campaign. |
| **Scene** | A played-out episode — an event-sourced transcript. |
| **Beat** | One "round" within a scene (the Director decides who acts each beat). Not a strict clock — a grouping. |
| **Turn** | One character's contribution in a beat (a "packet" of moves). |
| **Move** | A single unit inside a turn: **speech**, **thought**, **action**, **demeanor**, or a Director **world event**. |
| **The Director** | The world agent: paces the scene, casts who acts, narrates world events, proposes new characters. Not a character. |
| **View as / dramatic irony** | The play view can be seen as Omniscient (author) or as any character (their filtered knowledge). |
| **Control mode** | Per character: **Automated** (AI drives), **Draft & approve** (AI drafts, you approve), **I write their turns** (you author). |
| **Boundary** | A line a character holds, *played as a scene beat, never a content filter*. Can be a hard line, **conditional** (a slow-burn that releases once the story earns it), or open. Optional maturity **category**. |
| **Relationship** | A directional regard: how one character regards another (with an optional reciprocal — the other direction). |
| **Arc** | Durable changes discovered *during play* (what's now true of a character). Enter as **proposed**, become **canon** on author review. |
| **Content ceiling** | Per-campaign maturity config (adult on/off + category toggles) — the cap on what any scene can contain. |
| **Fork / branch** | Spin an alternate timeline off a scene at a chosen beat. |
| **Publish / snapshot** | Freeze a campaign into a shareable public copy. |
| **Visibility** | Per-entity: private / unlisted (share link) / public. |

---

## 3. Entity field reference (what forms & cards show)

**Character sheet**
- Prose (each is a multi-paragraph rich field): **premise**, **appearance**, **voice**,
  **temperament**, **backstory**. Plus a **name**.
- **Relationships** — list of `{who, how this character regards them}`; each links to an
  existing character or stubs a new one. (AI "Suggest" + per-item generation.)
- **Boundaries** — list of `{topic, stance, condition?, when-pushed?, category?}`.
  - stance ∈ **open** / **conditional (until…)** / **closed (hard line)**.
  - category ∈ *sexual / graphic violence / other / none* (links to the campaign ceiling).
- **Facts** — atomic true statements; some flagged **core** (always in play) vs long-tail.
  Each fact can be `concealed` (a secret).
- **status** — stub / proposed / **full** (only full characters are castable).
- **World** — which world bible grounds this character.
- Every prose field has: ✨ **Generate** (whole field), ➕ **Expand** (add a paragraph),
  per-paragraph rewrite; plus a "**Generate all fields**" from a one-line brief.

**World bible**
- **name**, **setting**, **tone**, **rules** (a list), **starting canon** (a list).
- Same generate/expand affordances.

**Campaign**
- **name**, **premise** (AI draftable/expandable).
- **Content ceiling**: adult on/off master + *sexual / graphic violence / other* sub-toggles;
  shows a live maturity label.
- **Model tuning** (advanced/collapsible): director "thinking" on/off, director & character
  token budgets, model + heavy-fallback model, service tier (standard/priority/flex).
- **World** (attached bible), **Cast** (character list), **Scenes** (list), **Publish**.

**Scene / play**
- **Transcript** of moves grouped into turns (speech / thought / action / demeanor /
  world event / enter–exit). Occlusion is silent per viewer.
- **Composer** — write as the selected character; whisper syntax `(whisper to NAME: …)`;
  **✨ Expand** drafts a turn you can edit before sending; **Continue** advances the Director.
- **Waiting states** — "The Director is setting the scene…", "X is writing their turn…",
  "Waiting for you to write X…", idle. Input is blocked while a beat runs.
- **Cast & control panel** — roster + each character's control mode.
- **Introductions queue** — the Director proposes bringing someone on: Admit / Generate &
  admit / Edit / Dismiss.
- **Turn controls** (author view) — Reroll / Edit / Delete on any committed turn.
- **Failures** — a generation that failed shows inline where it happened, with **Retry**.

**Arc entry** — `{kind: discovery|revision, about which field, statement}` awaiting Accept.

---

## 4. Screens to mock (priority order)

1. **Campaign editor (tabbed)** — the centerpiece; the new IA lives or dies here. Include
   the empty/first-run state (nothing built yet → Quick Build shines) and the populated state.
2. **Play (scene runtime)** — transcript + composer + view-as + cast/control + intro queue +
   inline failures + waiting states. Design the *author* (omniscient) view and a *character*
   view. This is the highest-craft screen.
3. **Character sheet editor** — prose blocks, relationships, boundaries, facts; the generate/
   expand affordances; the pending-stub state.
4. **World bible editor** — the four fields + generate/expand.
5. **Library / your stuff** — browse worlds, characters, campaigns; grouped; visibility;
   archive. (Entry point to editors; not a create-hub anymore.)
6. **Quick Build** — the seed form (world seed + character rows + "suggest off-screen
   relationships"), with a **progress state** (a bar reporting each phase) and a result state.
7. **Settings** — account, usage & cost (with **editable caps** — see §5), data controls.
8. **Auth** — login (magic-link), signup (18+ attestation + invite + consent).
9. **Browse / published** *(new — see §5)* — a reading/play/fork surface for public campaigns.
10. **Arc review**, **Admin (moderation)** — lower fidelity is fine for now.

---

## 5. Leave room for these (built-but-unsurfaced, or near-term)

The mocks don't have to fully design these, but should **not preclude** them — leave the
obvious slot. (Full list is the Capability Catalog's "Gap Register.")

- **Publish → consumer view.** Publishing exists but there's no way to *read/play/fork* a
  published campaign. Browse is currently bare title cards. Design a real published-campaign
  reading surface with **Fork** ("make my own copy") and **Use this character**.
- **Share links.** Going "unlisted" should surface a copyable **share URL**.
- **Branch / fork a scene** + a **branch navigator** (scene lineage) — timeline branching is
  built; give play a "Branch from here" and a way to see branches.
- **Auto / Play mode.** Today "Continue" advances one beat; leave room for a run-autonomously
  toggle.
- **Draft & approve affordance.** The "Draft & approve" control mode needs an approve/discard
  card in play.
- **Trash / recovery.** Archive & delete exist; **restore/purge** and a "show archived" view
  don't.
- **Per-campaign cost + editable caps + a report action.** Cost dashboard shows only a 24h
  number; caps are referenced but not editable; there's no "Report" action anywhere.
- **Arc review** should allow **reject/edit**, not just accept, and be **linked from the
  campaign** (today it's an orphan route).

---

## 6. Constraints for the mocks (so they port cleanly)

The target is **Phoenix LiveView + Tailwind**. Mocks in **daisyUI** are great — the markup
ports; here's how to make the port a copy-of-states rather than a reverse-engineer:

- **Mobile-first, both themes.** Phone is the primary viewport. Provide **light and dark**;
  don't just invert — check contrast in both.
- **Mock every interactive/async state as an explicit, static visual state.** For anything
  that's interactive or server-driven, show the states side by side: the **open** dropdown/
  modal/tab, the **loading** state, the **error** state, the **empty** state, the **success/
  toast**. Interactivity is re-wired server-side here (`phx-*` + hooks), so we port your
  *visual states*, not daisyUI's JS behavior. A tab flow, for instance: show each tab's panel
  as its own frame.
- **Server-rendered mental model.** No client-side routing; navigations are full/live page
  loads. Forms submit to the server and validate server-side (show the validated/error state).
  Long actions show a progress/waiting state (the server pushes updates).
- **Composable primitives.** Lean on a small kit — button, card, pill/badge, tab bar, form
  field, list row, modal, toast, progress bar, empty state — so the port maps daisyUI classes
  onto our components 1:1. Call out the **status colors** you use (semantic good/warn/critical,
  separate from the brand accent).
- **Copy is design material.** Buttons say exactly what happens ("Publish" → toast
  "Published"); errors say what went wrong and how to fix it. Use the §2 vocabulary.

**Existing palette to riff on (optional).** The current app uses a blue-biased dark neutral
with a periwinkle accent (`#8ea2ff`), a violet secondary (`#a78bfa`), and green for success —
you're free to establish a fresh identity, but that's the starting temperature.

---

## 7. What to hand the mock thread

1. **This brief** (paste it in).
2. **The Backend Capability Catalog** artifact link (the Gap Register = the "leave room for
   it" list).

That's everything — no repo access needed.
