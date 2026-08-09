# Character sheet

<!-- rev: 3 -->

| | |
|---|---|
| Route | `/authoring/character/:id` |
| Storybook | Screens → Character sheet |
| Code | `PolyphonyWeb.Screens.SheetEditor`, `PolyphonyWeb.SheetEditorLive` |

Writing a person. Everything a character prompt renders comes from this screen, so what is
missing here is what a model will invent.

## Standing decisions

- **Pronouns are a field, not an inference.** Every character prompt renders this sheet, and
  a model guessing from a name lands its wrong guess *inside the fiction*, where it reads as
  the story being wrong about her rather than as a settings mistake.
- **Secrets are written from the secret's side.** The "who else knows" control names an
  audience per secret. Written the other way round — per character, what do they know — it
  would scale with secrets times cast instead of with secrets. The control is always
  present, and concealment is what it reports.
- **An audience is additive only.** A tick inherited from a group cannot be individually
  removed, and the picker says so rather than offering a control that silently does nothing.
- **A relationship targets an id, with a name rendered beside it.** A name is display, and two
  people can share one.
- **The campaign's content ceiling is applied here, not only in play.** A boundary flagged
  for content the campaign doesn't allow is saved **held** — and held as a *refusal*, so a
  compulsion becomes a line against the same topic rather than something she always does.
  Play would cap it either way; capping it in the editor is what stops an author saving an
  open boundary and believing it. The screen says which category and where to change it,
  because the fix is on the campaign screen. A character in **no** campaign has no ceiling
  and nothing is capped — the all-off default means *this campaign permits nothing*, which
  is the right reading for a campaign and the wrong one for a character without one.
- **Editing a field play has already revised asks which you mean.** Everything else on this
  sheet edits without ceremony; the friction appears exactly where the ambiguity is. Once arc
  has touched a field there are two different things an author can be doing and the app
  cannot tell them apart from the keystrokes: *she has changed again* adds to what play did
  and leaves her history standing, while *I wrote her wrong* corrects the person you
  originally wrote and lets play's changes still apply on top. Guessing produces a sheet
  whose history is quietly false, which is the one thing arc exists to prevent. Fields arc
  has never touched have no such ambiguity and get no such prompt.
- **Concealment is what the audience says, not a flag beside it.** A fact carries an audience
  and nothing else; it is secret when somebody other than her is on it. Dropping the separate
  toggle removes a pair that could disagree — a fact marked secret with an empty audience, or
  an audience with the mark left off — and removes the row whose caption described the default
  rather than the control. *Nobody* is the honest resting state and reads as a fact about the
  world rather than a setting you left off. `bible_editor.md` takes the same edit; the two use
  the same row and must not answer this differently.
- **The save bar is pinned to the frame, not to the document.** On a phone, a save control at
  the bottom of a long form is a save control nobody finds.

## States

### `written` — A sheet with something on it

The ordinary working state: the five prose fields, the facts, and the panels behind them.

### `blank` — A character who exists and nothing more

A first-run card leads instead of five empty fields. An empty form is a worse question than a
prompt.

### `a_secret` — A fact somebody else knows

Not a mode the fact is put into: the audience picker is always on the row, and this is what
the row looks like once anybody besides her is named. The purple treatment is derived from
the audience rather than stored beside it.

*Always in mind* sits above it and is unrelated. She can have a secret she never thinks about
— the case worth having a state for, since every other combination is obvious.

### `audience_open` — The picker

Groups and people, with somebody already in the audience. Additive only — see the standing
decision.

### `boundaries` — What she won't do

And which way the pressure runs: a **refusal** is a line she holds, a **compulsion** is one
she can't help crossing. Same gate, two directions, and both are enforced in play rather than
suggested to a model.

A line is also either **never** or **earnable**. A *never* is a hard line whatever happens.
An earnable one — *not until…* — carries two more things: the **until**, the condition that
would move it, and the **and then**, what she does once it has. The consequence is written
when the line is created rather than when it gives, and **she is not told it** until it
happens; a character who knows how she will break is not holding a line, she is waiting.

That pair is what makes a line have an open and a closed state, and closing one is an arc
event rather than an edit — see `arc_review.md`. A *never* has no condition and therefore no
closed state; it can be removed, or rewritten as earnable, but those are decisions about who
she is rather than things the story did to her.

Adding one applies the campaign's ceiling on the spot — see the standing decision. A
suggestion is the likeliest way an over-the-ceiling item arrives, since nothing tells the
model what the campaign permits, so a batch of them reports how many came back held.

### `arc_touched` — Editing a field play has revised

The field carries how many times play has changed it. Editing does not save on blur; it asks
which kind of change this is, and the two answers land in different places in her history.

**She's changed again** writes a new entry at the point it happens. It takes an **optional
scene** — a closed scene it belongs to, or nothing at all, in which case it is true from now
and tied to no scene. Between-session changes are real changes, and forcing one to name a
scene it didn't come from would put a falsehood in the provenance line that exists to prevent
exactly that.

It also takes an **optional *Because***, the same line an extracted proposal carries. The
common reason to write one is not invention but bookkeeping — a scene had a consequence for
somebody who wasn't in it, or wasn't shown reacting, and the reason is right there in the
scene. Recording it makes the entry read like every other entry, which is what somebody
reading her history a year from now needs. Left empty it stands on the author's name alone,
which is enough for *I just decided this*.

**I wrote her wrong** rewrites the origin rather than adding to the timeline. What play has
concluded since still applies on top, so correcting the version of her you first wrote does
not discard two scenes of consequences — which is the fear that would otherwise stop somebody
fixing a temperament they never liked.

An entry written here is a **proposal**, not an applied change. It joins her pending list and
is accepted or refused like any other; see `arc_review.md`. Writing one and then accepting it
is two taps, and that is deliberate — a sheet has one way to change, and an authoring
shortcut would be a second one.

### `relationships` — Who she's connected to

Both directions of the connection, since what she thinks of him and what he thinks of her are
different facts.

### `generating` — A field being written

The skeleton is per-field, so the rest of the sheet stays editable while one field thinks.

### `dirty` — Unsaved

The save bar, pinned. See the standing decision.

### `in_scenes` — Already played

A scene count, as a quiet warning. Renaming her is safe; what she has already said is in the
event log and isn't editable from here.
