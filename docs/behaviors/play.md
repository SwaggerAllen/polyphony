# Play

<!-- rev: 1 -->

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
- **The composer answers a specific slot at a specific beat.** Not "the next free moment" —
  a turn committed at whatever beat happens to be current is how one beat ends up with two
  turns from the same person.

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

### `intros_panel` — Bringing somebody in

Two lists, kept apart: characters who can walk in now, and the walk-ons this story invented
for itself and never wrote. The second list gets its own control because the honest offer is
*write them, then bring them in* — a scene refuses a character who isn't fully written, so
offering one as a one-click entry would be offering a choice that can't be honoured.

### `intros_exhausted` — Nobody left to bring in

Worth its own state: an empty panel that says nothing reads as broken.
