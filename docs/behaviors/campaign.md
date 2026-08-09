# Campaign

<!-- rev: 4 -->

| | |
|---|---|
| Route | `/campaigns/:id` |
| Storybook | Screens → Campaign |
| Code | `PolyphonyWeb.Screens.Campaign`, `PolyphonyWeb.CampaignLive` |

Everything about one story that isn't playing it: its cast, its world, its pitch, its
scenes, what it is allowed to contain, how it gets published, and the three ways it ends.
Six tabs, in the order somebody meets them — Settings, World, Cast, Groups, Premise, Scenes.

## Standing decisions

- **Premise comes after Cast**, because the pitch is written *from* the cast and that is
  also what the Expand button reads. The title lives with the premise rather than in
  Settings: a title isn't configuration, it is the first line of the pitch.
- **Quick Build is a card, not a tab.** It is a one-shot, and a tab for it would be dead
  weight from the second day of a campaign's life. It appears only on first run — and the
  build card that reports its progress sits *outside* it, because the build that empties
  "first run" would otherwise take its own progress bar off the screen.
- **Attaching a world copies it.** A campaign accumulates its own world arc, so two
  campaigns cannot share a bible. The copy is labelled as one, so nobody edits it expecting
  the original to change.
- **A group belongs to a campaign, not to a world**, the same rule characters follow.
  Attaching a world brings no groups with it — they are written per campaign, and a group
  written in one story never appears in another. Groups get their own tab and it sits
  **beside Cast**, because a group is written with the character editor and seeds the
  people it produces; it is a kind of person, not a kind of setting. It is not part of
  first run: a campaign is ready to play without one, so the tab carries no *to do* mark
  where World, Cast and Premise do.
- **Publishing a head is a spoiler control, not a reading preference.** Nothing is ticked by
  default. The list is in **tier order**, not roster order — the roster is the accident of
  how the campaign was built, the tier is the author's own statement about who the story is
  about.
- **The three endings are three controls, not one with a severity dial.** Archive, trash and
  start-over are genuinely different acts with different reversals. Only start-over confirms,
  because it is the only one that isn't reversible.
- **A premise is not a setting.** Quick Build takes them as two fields because one box
  produced a specific failure: "a smuggler owes the harbour-master a favour" typed as a
  world seed goes into the bible's *canon*, and every later campaign in that world inherits
  it as permanent truth. A world is where stories happen; a premise happens to one cast,
  once. An author's premise is kept verbatim — only the title is generated from it, because
  a generated title is worth having and a generated rewrite of what you just typed is not.
- **A scene is a chapter, so it is named by number and place.** *Scene 2 · The quay* rather
  than twelve characters of a stream id. The id is still the routing key and still the link
  target; it was never a name a person could hold, and a list of them read as a column of
  near-identical hex. A number is a **position**, so deleting one renumbers the rest.
- **Deleting a scene takes the arc proposals it raised.** The same asymmetry restart has: a
  question play asked about a character, left behind after the scene that asked it is gone,
  is a review item nobody can answer. The event stream is abandoned, not erased — events are
  immutable, and nothing reads a stream no campaign names.
- **The scene's premise is the scene's.** Every scene used to open on the campaign premise,
  which is the pitch for the whole story and says nothing about what is happening now. Blank
  still falls back to it.

## The perspective control

Present in the header, and it drives the **World** tab: what a character knows of the world
resolves group membership *live*, so somebody joining a group changes this read without
anybody touching a secret. Behaviour and placement are defined in `play.md` and must not
diverge.

## States

### `settings` — What it can contain, and what writes it

The content ceiling stated in the author's vocabulary rather than the config's — a ceiling,
not a target, with each character's own limits still holding underneath it. Model tuning is
flat rather than folded: a settings page is read by scrolling it, and a fold hides a section
behind a guess about whether you wanted it.

### `first_run` — A campaign that is nothing but a name

Quick Build leads. Amber dots mark the tabs with nothing built yet; they go the moment
anything exists anywhere.

### `quick_build` — The one-shot, open

A world, a premise, and a concept per character. Two switches, both off by default because
each is another provider call: off-screen relationships, and writing the groups the world
names.

The premise field is **separate from the world seed**, and that separation is the point —
see the standing decision. Left blank, one is still written from the world and the cast.

### `quick_build_existing_world` — Building on a world you already wrote

The world seed disappears rather than greying out: a brief for a world nobody is going to
write is a field whose text is silently discarded. The chosen world is attached to the
campaign **before the build starts**, following the same rule the build uses for a world it
writes itself — associate the moment the thing exists, so an interrupted build leaves a
half-built campaign rather than loose parts.

### `building` — A build in progress

Drawn from the build's own row rather than from socket state, so it is the same card whether
you started it, came back on a phone, or reloaded mid-run. It says the work is on the
server — which is the sentence that makes leaving safe.

### `build_failed` — A build that stopped

It **resumes** rather than restarting, so it costs only what is left to do.

### `world` — The attached world

Read, not edited: every field the editor has, because this is where a world gets reviewed and
a review of half of it is a review of nothing. Each section is guarded, because a world
attached by hand can be a name and nothing else.

### `world_none` — No world attached

A campaign can play without one, but the Director has much less to go on. The empty state
offers writing one, which for a long time nothing in the app could do.

### `world_as_character` — The world through one character's eyes

Said out loud, in the secret tint, because the value of the control is knowing which read you
are looking at — a page that silently drops three rules looks like a page missing three
rules.

### `cast` — The people

Main cast reads as the short list you authored; walk-ons collapse behind a count.

### `cast_pending` — Stubs waiting to be written

They arrive in batches from other people's relationships, so one button fills them all rather
than twenty trips through the editor.

### `cast_empty` — Nobody yet

A campaign needs at least one character before a scene can open. The empty state offers the
write rather than explaining the rule.

### `groups` — The collectives this story has

A crew, a household, an order. Each row says what membership is worth: how many people are
in it, whether anyone can be written from it, and how many secrets it carries — the three
things that make a group different from a list of names. The card closes by saying what
being written from one gets you, because that is the part nobody guesses.

Only **this campaign's**. A group written in another story is not here, and neither is one
belonging to no campaign at all.

### `groups_empty` — None yet

The empty state makes the case rather than describing the feature: a group saves writing the
same person five times, and gives secrets somewhere to point. A campaign is perfectly
playable without one, so this is an offer and not a gap — which is why it has no *to do*
mark on the tab.

### `publish` — What a reader gets

Spectator, heads, forkable. See the standing decision.

### `publish_gap` — A scene nobody will be able to read

Named, before publishing rather than after. The gap can be the point; it just must not happen
by accident.

### `premise` — The pitch, and the title

Expand deepens whatever is saved, grounded in the world and the cast, so it reads best once
both exist. With no title yet, it writes one too.

### `scenes` — Setting one

Where it happens, what is already true when it opens, and who is in it. Who's in it is a
choice with a cost — the roster is what turn order walks — and everyone ready is the default,
so an author who never touches it gets exactly what they got before.

**Every cast row carries that character's arc state**, which is the gate made visible as you
build the scene rather than as a refusal when you submit it. Four things a row can say:

- **Up to date.** Nothing pending. The ordinary case.
- **_n_ changes to say yes or no to**, with *Accept all n* on the row and a caret to read
  them first. One tap is always available: the person who wants to read expands, the person
  who wants to play taps once, and both end up consistent.
- **Still being worked out.** Extraction is running. A wait, not a fault — see
  `arc_review.md`.
- **Couldn't be worked out.** Extraction failed. See `scenes_gate_failed`.

A row also carries how that character will be played, so the two facts about somebody going
on stage are read together.

**The world takes a row of its own, above the cast and set apart from it**, whenever it has
pending changes. Pending world proposals gate every scene in the campaign whoever is in it,
so without a row the form refuses to open for a reason that names nobody in it — which reads
as a bug rather than as a gate. It sits above the cast because it outranks them: clearing
every character still won't open the scene. It sits in its own band because it is not cast —
nobody can select or deselect it, and putting it in the list proper would imply otherwise.
With nothing pending against the world, the band is absent rather than empty.

When proposals are pending on people **not** in this scene, the form says so and says they
can keep waiting. The backlog is visible but not in the way, which is the per-cast rule
expressed as a sentence rather than as an absence.

The submit control says how many people aren't ready and that sorting them lights it up. It
is a statement of what remains, not a refusal — the work is all on the rows above it.

Below the form, the scenes already played: **newest first, numbered by position**, each with
its beat count and the premise it opened on. The numbers therefore count down, which is what
a reverse-chronological list of chapters looks like. Each row carries a delete that names
what goes with it — see the standing decision.

### `scenes_gate_expanded` — Reviewing a character's changes on the row

The caret opens the proposals in place, **as the same cards the review screen shows** — not a
summary of them. Each carries what it would change, what it changes it **from**, and the
*Because* line naming what in the scene caused it, with *True*, *Edit* and *No* on each.
Beneath them, *Accept the rest* for whatever is left, so reading two of four does not commit
you to reading four of four.

The full card rather than an abbreviation is what makes navigation unnecessary. An author
deciding whether Wren has really stopped signing the register needs to see what her
temperament said *before* and why the scene concluded otherwise; abbreviating to *replaces
her temperament* sends them to the sheet to find out, holding a half-built scene. §04c of the
mock draws the abbreviated version while claiming identical controls to the review screen —
the controls are identical, the content was shorthand, and the shorthand is the reason this
question kept coming up.

**Last in the expansion, a row for adding one yourself.** The fan-out proposes what the scene
concluded; it does not propose what it missed. An author who knows a scene changed somebody
in a way the extraction didn't catch has, until now, had nowhere to say so at the moment they
noticed — which is here, looking at the things it did catch. It opens `arc_review.md`'s
authoring states, with this character and this scene already filled in, since both are known
from where the row was tapped — `authoring_list` for a fact, `authoring_line` for a boundary,
and so on by what is being changed.

A card here may carry a different action set — a line that gave in play takes *True / Not
yet*, and a world fact proposed as common knowledge takes *True / Only who was there*. The
row's *Accept all* covers all three the same way; the difference only shows when somebody
reads before tapping. See `arc_review.md`.

Refusing one proposal here is the same act as refusing it on the review screen, and
`arc_review.md`'s standing decision about refusal applies unchanged.

### `scenes_gate_failed` — A character's changes couldn't be worked out

The row says so and expands to explain: the model is busy, it usually clears in a few
minutes, and — the part worth keeping — *a scene would be struggling too until it does.*
**Try again** is the only action.

**No open-anyway**, and the reason is not caution. Arc extraction and turn generation call
the same provider, so a row that can't extract is evidence the scene can't run. An escape
hatch would move the failure to one beat after the author committed to playing, which is
worse. See the standing decision in `arc_review.md`.

Per-row rather than per-form, because failure is per-character: one person's extraction can
fail while everybody else's succeeded, and a whole-form error would claim the scene is broken
when three of four rows are fine.

### `scenes_write_in` — Writing a walk-on into the scene

Offered right where you pick a cast, because sending somebody to another tab to run a batch
they didn't ask for is not the answer. Written in, they are selected.

### `scenes_empty` — Nothing has happened yet

On a campaign with a cast ready to make it happen.
