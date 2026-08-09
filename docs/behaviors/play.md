# Play

<!-- rev: 4 -->

| | |
|---|---|
| Route | `/play/:scene_id` |
| Storybook | Screens → Play |
| Code | `PolyphonyWeb.Screens.Play`, `PolyphonyWeb.PlayLive` |

A scene as it happens. The screen the product exists for: several characters and a Director
taking turns in one room, where **each of them knows something different** and the
difference is a property of the data rather than an instruction anybody gave a model.

## Standing decisions

- **A filtered scene is a shorter scene.** When you read as a character, what they were
  never told is simply absent — no markers, no redaction bars, no "3 lines hidden". A marker
  is itself information, and the whole guarantee is that a character's view contains nothing
  they don't know. This is a standing decision, not an oversight, and reversing it is a
  design change with a real argument to make.
- **Two registers, one screen.** *Stage* is the working view — gutter labels, interiority,
  controls. *Page* is reading — the labels go and the type gets bigger. Same content,
  different job; the perspective control is what moves between them.
- **A failure is a visible gap, not a stall.** When a turn can't be generated, the beat says
  so in place and carries on closing around it. It is scoped per viewer, so one character's
  read never shows somebody else's error.
- **A dropped socket is not a failed turn**, and the two must never be said the same way. A
  generation failure is a hole in the fiction and carries a retry; a lost connection is the
  transport, and everything on screen is still true — it has simply stopped being live. They
  look identical from the seat, which is exactly why the copy has to distinguish them.
- **The composer answers a specific slot at a specific beat.** Not "the next free moment" —
  a turn committed at whatever beat happens to be current is how one beat ends up with two
  turns from the same person.
- **Every path into a scene ends with a full character.** There is no admit-as-a-stub. A scene
  refuses a character who isn't fully written, so offering an unwritten walk-on as a one-click
  entry would be offering a choice that can't be honoured — and the panel used to do exactly
  that, in a second list. The three doors are: admit somebody the Director suggests, write
  somebody new, or find somebody already written. Each ends in a sheet. What differs is only
  how long the sheet takes to arrive, which is `admitted_writing`'s problem rather than the
  panel's.
- **The picker reaches the campaign, not the library.** A character search opened inside play
  looks like the library's and is built from the same component, and the temptation is to let
  it behave like the library's too — everything the author owns. It must not: characters do
  not cross campaigns. The distinction that *is* real is a different one — the Director can
  only suggest from the cast and its off-screen stubs, while the GM reaches the **whole
  campaign roster**, including walk-ons the Director would never think to propose. That is
  what the picker is for. Written down rather than left to the scope rule to imply, because
  this is the one surface where the author's entire library feels like it should be a
  keystroke away, and therefore the one place the rule will be broken by somebody being
  helpful.

## The perspective control

Play is where this control is defined, and it appears on the campaign screen's world tab and
in the published reader too. It behaves identically in all three places: the same markup, in
the same position, naming *Omniscient* or one character. It is the thing that decides which
projection of the log you are looking at, so it is never styled as a filter or tucked into a
menu — drift between its three treatments was the worst consistency failure of the design
pass, and it is not to be repeated.

## States

### `stage` — Omniscient play

Everything visible, interiority included, and the composer writes as whoever the perspective
control names. This is the author's working view of their own story.

### `page` — Read as one character

The same scene as Wren. Gutter labels gone, type larger, and shorter — because what she was
never told isn't there. See the standing decision above.

### `empty` — A scene nobody has played

The state most likely to be wrong and least likely to be seen: the moment anybody tests the
app they have already written a turn into it. It has to say what happens next rather than
render as a blank stage.

### `director_writing` — The Director is composing

A placeholder with the beat's own rules and skeleton lines, so the scene reads as *moving*
rather than as hung. An absence and a wait look identical, and only one of them is fine.

### `generating` — A cast turn is being written

The status strip names **who**. A tracker that goes quiet while time passes is the thing
people read as broken.

### `awaiting_you` — Your turn

The loop walked to a user-controlled slot and stopped. The composer is bound to that slot at
that beat.

### `failed_turn` — A turn couldn't be written

Rendered in place, per the standing decision. The scene continues.

### `auto_running` — Full auto

The loop runs itself. It ends in exactly three ways — the Director closes the scene, the room
empties, or the fifty-beat cap — and that set is the design, because an auto mode with no
stop condition is a way to spend money by accident.

### `auto_paused` — Paused

The pause is a **row in the database**, checked at the top of every beat, not a message to a
running process. It therefore survives the tab that set it, a reconnect, and a redeploy.

### `auto_stopped_at_cap` — The cap was reached

It names which of the three ends it hit. To a reader, *it stopped* and *it finished* are
different events and only one of them wants a button.

### `draft_pending` — A generated turn, waiting on you

Accept it or discard it. Play has always worked this way; authoring does not, and closing
that asymmetry is open work.

### `who_panel` — Who is this?

A reader meeting a name for the first time gets **what the scene has actually shown them**
plus that character's cover. Never the sheet — the sheet is the author's, and half of it is
things this reader is specifically not supposed to know.

### `intros_panel` — The Director asks, the GM decides

One suggestion, named and reasoned: who, and the half-line of why — *somebody rang that bell*.
The reason matters more than the name, because the GM is being asked to ratify a judgement
about the scene rather than pick from a roster.

Three controls, and they are not equal. **Admit** takes the suggestion. **Not now** declines
this one without closing the panel. And *she'll be* sets how the character will act before
they are in the room, because the answer changes what admitting them means and it is much
harder to explain after the fact.

Below the suggestion, under its own heading, the GM's two doors: **write someone new** and
**find someone you've written**. They sit apart from the suggestion because they are a
different act — the Director proposed something and you are declining to be led.

### `intros_no_suggestion` — The Director isn't asking for anyone

The panel opened and the Director has nobody to propose. It says so, and says it will ask when
the scene needs someone — which is the difference between a system with nothing to say and a
system that has stopped working.

Both doors stay. This is the state that makes the panel's own controls load-bearing rather
than a fallback: on a two-hander that never needs a third voice, this is the only version of
the panel anybody sees.

### `intros_write_new` — Writing somebody into the scene

The inline form, opened from the panel without leaving play. Two fields — a name and *who are
they*, a sentence or two — plus the same *she'll be* control the suggestion carries.

The primary action writes them **and** brings them on; a secondary offers the full sheet
editor instead. The note under it is the important part: *either way she joins your cast as a
full character*. Somebody typing one line into a scene needs to know they are not creating a
throwaway.

### `intros_picker` — Find someone you've written

The shared character picker, opened inside play. Search, tier filter, and rows carrying a
face, a name, a half-line and their tier.

**Scoped to this campaign** — see the standing decision. Not the author's library, not another
campaign's cast. What the picker adds over the Director's suggestion is *reach within the
campaign*: walk-ons and minor players the Director would never propose, which is precisely the
roster that gets long. Tier is therefore the primary filter rather than an afterthought.

Two bands. Characters in this campaign but not in the scene are pickable. Characters **already
in the scene** appear too, dimmed and inert — showing them costs a row and prevents the GM
hunting for somebody who is standing in front of them.

### `intros_picker_empty` — No matches

The search found nobody. It does not stop at saying so: the offer is to **write** the thing
that was searched for, carrying the query into the name. Somebody who typed *alchemist* and
found none wants an alchemist, and the panel already has a door for that.

### `intros_picker_confirm` — Chosen, not yet admitted

A second step rather than one-click entry from the row. It shows the face, the tier, when they
were last seen, and their cover line — enough to catch *wrong Sable* before she walks in — and
it carries the *she'll be* control, because this is the last moment before the character is in
the room.

### `intros_arc_gate` — They're behind, and this is where you catch them up

Casting somebody is casting somebody wherever you do it, so the arc gate is met here too —
on the way in from the picker, and on the way in from a Director proposal. A character enters
as their sheet reads, so admitting one with unreviewed arc puts somebody two scenes out of
date on stage, which is the same staleness the scene-setup gate exists to prevent.

**The same cards, not a summary of them** — `arc_review.md`'s, with the same accept, edit and
refuse. *Accept all and bring them on* is one tap and carries straight on into the entrance it
interrupted; *Not now* leaves them out of the scene and their arc exactly where it was, because
nothing was half-done.

Only **their** pending arc counts. Pending world arc gates *opening* a scene, since a world
fact is true for everybody — but this scene is already open, and the world's backlog says
nothing about whether this person's sheet is current.

### `admitted_writing` — In the room, sheet still being written

They are in the scene and cannot act until the sheet lands; the beat carries on without them.
The entrance reads as fiction first — *a man comes up the steps from the water, still holding
the bell rope* — and nobody sees a sheet being written. That is the whole point of admitting
before writing finishes, and it is why the roster's line and the transcript's line say
different things.

### `admitted_failed` — In the room, and writing them didn't work

Distinct from `failed_turn`: that is a turn that couldn't be generated inside a working scene,
and this is a character with no sheet who is already standing in it. They stay in the scene and
still cannot act. Three ways out, genuinely different rather than a retry with decoration:

- **Try again** — re-run the write.
- **Write him yourself** — the same form as `intros_write_new`, pre-filled with whatever the
  entrance already committed to.
- **Send him away** — a departure, not an undo. The entrance has already been narrated and
  other characters could have reacted to it, so removing the character cannot mean erasing it.
  The fiction absorbs it — *he goes back down the steps* — the same shape the Director uses
  when it rules against a proposal. That keeps the log append-only, keeps a reader who saw the
  entrance from being shown a scene that contradicts their memory, and lets the character be
  brought on again later with nothing to reconcile.

  The confirm names **what survives** rather than what is destroyed, because nothing is — that
  deliberately inverts the name-what-dies pattern used for deletions elsewhere, since the fear
  here is that the action is irreversible when it isn't. Afterwards the roster simply no longer
  lists him: no tombstone, no struck-through row. The roster is who is here now; the transcript
  is what happened, and only one of them should remember him.

### `reconnecting` — The socket dropped and is coming back

The state a real reader hits on a train, and it promises recovery rather than describing a
fault: reconnecting replays the canonical log, so nothing written is at risk and the sentence
can say so.

Driven by the class LiveView puts on the container, not by an assign — which is what makes it
free of server state, and what kept it out of this document until now. The storybook variation
sets the class through a per-variation template so it can be looked at like anything else.

### `disconnected` — The socket is gone

Not coming back on its own. See the standing decision: this is the transport rather than the
fiction, so it says the scene will catch up rather than offering a retry, because there is
nothing here to retry.
