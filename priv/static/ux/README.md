# Polyphony — UX & IA pass

Design output for the frontend rework. Everything here is a **static mock**: real markup, real
CSS, no behaviour. Interactivity gets rewired server-side, so what's being handed over is a set of
*visual states* to port, not JavaScript to reuse.

---

## What's in the folder

| File | What it is |
|---|---|
| **`polyphony-kit.css`** | **The single source of truth.** Tokens and every component class. Each screen links it and defines nothing of its own. |
| **`polyphony-kit.html`** | The visual catalogue — every component and state, with the rules that govern each. Read this before building anything. |
| _(backend asks)_ | The design's backend dependencies now live in the repo docs as **`docs/backend-backlog.md`** (renamed from this folder's `backend-asks.md`), the standing engineering worklist. |
| `polyphony-play.html` | Scene setup, both play registers, status strip, draft-in-composer, connection states, introductions |
| `polyphony-campaign.html` | Campaign editor — Settings, World, Cast, Groups, Premise, Scenes, Quick Build |
| `polyphony-character.html` | Character sheet — prose, facts, relationships, pressures, groups, the stub |
| `polyphony-world.html` | World bible — cover, four fields, secrets, reuse, sharing |
| `polyphony-audience-picker.html` | The shared "who knows this" component, in depth |
| `polyphony-arc.html` | Arc review, world arc, group fan-out, the gate, sheet time travel |
| `polyphony-library.html` | Your stuff — campaigns, reading, worlds, people, groups, archive and trash |
| `polyphony-browse.html` | Published campaigns, the reading surface, perspectives, forking |
| `polyphony-settings-auth.html` | Account, spending caps, sign-in, signup |
| `polyphony-admin.html` | Moderation queue, reports, take-downs, invites, roles |
| `archive/` | Superseded explorations. Kept for reasoning, not for building. |

**Open the files with `polyphony-kit.css` beside them** or they render unstyled. The folder ships
together.

---

## The one idea everything else follows from

*Dramatic irony is data, not a prompt.* Every character sees a filtered projection of what
happened. Another character's thoughts, whispers they weren't part of, events before they arrived
— structurally invisible, not hidden behind a permission check.

Two consequences shape every screen:

**Occlusion is silent.** No locks, no greyed rows, no "hidden" placeholders. A narrower view is
just a shorter scene. The only exception is a whole scene a character wasn't in, which needs
explaining or it reads as a bug.

**The perspective control is the product's spine.** Same markup, same position — top right of the
header — on play, reading, contents lists, and preview on the world bible and character sheet. It
drifted into three treatments during design and that was the worst consistency failure of the
pass. If you're building a screen with a viewpoint, it uses `.viewas` and nothing else.

---

## Two registers, not two design systems

The axis is **working vs reading**, not author vs player.

- **`.stage`** — omniscient play, and every authoring screen. Machinery visible, gutter labels,
  editorial controls.
- **`.page`** — a player in their own character's head, and published campaigns. Wider measure,
  larger body, machinery at the edges.

Same tokens, same components, different density and warmth. The reading register is used on
exactly two surfaces, which is what stops it being a one-screen orphan.

---

## IA decisions the mocks embody

**The campaign is the hub, and there's one create button.** Worlds and characters are made inside
a campaign. The library finds things; it doesn't create them.

**Campaign tabs: Settings · World · Cast · Groups · Premise · Scenes.** Two changes from the
original brief, both argued in the mock: Quick Build isn't a tab (it's a one-shot, dead weight from
day two), and Premise comes after Cast (the pitch is written *from* the cast).

**Nothing is deleted, only archived.** Characters are referenced by every transcript they appear
in. Archive is a filter, off by default everywhere; trash has a countdown and that number is the
point.

**Attaching a world copies it.** A campaign accumulates world arc, so two campaigns can't share one
bible. Library worlds are templates. This removes the entire shared-artifact hazard class.

**Characters never cross campaigns.** A sheet is written against a world, and the people who'd want
to move one want the arc and relationships — exactly the part that doesn't port. Browse lists
stories and worlds, not people.

**You author omniscient and preview read-only.** Editing a sheet while seeing a filtered version of
it is how someone deletes something they couldn't see.

**Nobody plays without a full sheet.** Admitting a walk-on autogenerates one. Stubs are a transient
authoring state, written on demand or on scene entry — never automatically, or relationship
generation recurses.

---

## Copy rules

The vocabulary is the product. A few that recur:

- **Say what happens, not what the rule is.** "They'd be played as they were before it" beats "arc
  review required."
- **The model's vocabulary isn't the author's.** *Always in mind*, not `core: true`. *What she
  won't do*, not `stance: closed`.
- **Empty states are in the fiction's voice.** "Nobody is on the quay yet," never "No items found."
  A Spectral headline, a plain line of explanation, one action.
- **Name the destruction in units that mean something.** "Three scenes, five characters and a
  world," not "this campaign."
- **Errors say what went wrong and what happens next.** "The model is busy. It usually clears in a
  few minutes, and a scene would be struggling too until it does."
- **Pronouns are a field.** Half the copy on a character sheet is written about them, so those
  strings need parameterising rather than hardcoding.

---

## Porting notes

**Tokens → daisyUI theme.** The mapping is commented at the top of the kit. Four semantics carry
meaning and shouldn't be re-coloured: **lamp = now**, **pencil = correction** (never a primary
action), **ok = done**, **secret = concealed**. Voice colours `--v1`–`--v8` are assigned by cast
order and must be stable — the same character is the same hue in the transcript, the strip, the
cast list, the picker and their sheet.

**Components worth building once:**

| Component | Used by |
|---|---|
| `.viewas` perspective control | play ×2, reading, contents, world bible, character sheet |
| Audience picker | world canon, character facts, arc entries, locations later |
| Prose generation states | world bible, character sheet, campaign premise, scene premise |
| Character row with tier + control mode | scene setup, cast tab, introductions, library, arc gate |
| Arc proposal card | arc review, and inline in the casting gate |
| Status strip | both play registers |
| Info drawer | one per section, everywhere |

The arc proposal card and the character row are the two most reused and the two most likely to get
built twice — the casting gate renders arc proposals inline specifically so nobody navigates away
mid-setup.

**Every async state is drawn.** Generation has writing / proposed / replacing-your-words / failed.
Anything server-driven has loading, error, empty and success frames somewhere in the files.

**Long lists: render everything for now.** Realistic ceilings are small and structure does the work
pagination would. If a group gets long, add search before paging; if paging is eventually needed,
"Load more" over infinite scroll — it fights back-navigation. Keep rows independent of their
neighbours so windowing later is a query change, not a markup change.

---

## What isn't designed yet

- **Info drawer copy.** The `i` affordance is placed on all 21 locations that need it — the
  inventory and the test that produced it are in `polyphony-character.html` §06b — but only three
  drawers are written out in full. The remaining eighteen need their copy drafting.
- **Locations** as authored entities. Three asks get simpler once they exist; none of them get
  rebuilt. The audience picker already has the shape tested.
- **Triggers and events.** A new authoring surface. Its only reach into current work is
  provenance — arc review can already say *this came from a trigger*.
- **Real multiplayer.** Currently a conceptual constraint on a single-player UI: whoever has a
  character's perspective may change that character's settings. Cast rows are rows rather than
  chips specifically so invitation state has somewhere to go.
- **A profile page**, and with it the per-campaign opt-in for experimental generation behaviour.

---

## Read `docs/backend-backlog.md` before estimating

Several designed screens depend on work that doesn't exist. The two that gate the most:

**§5.1 — scene-close fan-out has no caller.** Not from this design pass; it's in the existing
capability catalogue. Per-character summaries and arc extraction never run in production, so arc
review, world arc, the casting gate and published-campaign contents are all decorative until it's
wired. It's the single highest-leverage fix in the document.

**§2.8 — world arc doesn't exist.** There's nowhere for "the moon fell out of the sky" to live as
durable canon, and no way for it to reach a character who was off-screen. This bites inside a
single self-contained campaign with no sharing features at all.

The file also records **scope decisions** (§2.7 characters don't cross campaigns, §3.1c publication
is two independent settings) and **confirmed non-asks** — things deliberately ruled out, so nobody
builds them speculatively. Its immediate-milestone section is the slice that gates these mocks.
