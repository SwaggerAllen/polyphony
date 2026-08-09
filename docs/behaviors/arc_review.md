# Arc review

<!-- rev: 3 -->

| | |
|---|---|
| Route | `/arc/:campaign_id` |
| Storybook | Screens → Arc review |
| Code | `PolyphonyWeb.Screens.ArcReview`, `PolyphonyWeb.ArcReviewLive` |

What play decided about your people and your world, **proposed rather than applied**. A
scene can conclude that Wren no longer trusts the harbour office; this is where you decide
whether that is now true of her.

The gate's *states* live in `campaign.md` — the cast rows on Set the scene carry them, and
`scenes_gate_expanded` and `scenes_gate_failed` are where a row is opened. This screen owns
the rules, the queue and the per-scene backlog; the casting form owns the moment you meet
them. Writing an entry by hand is described here and in `sheet_editor.md`, which owns the
other door into it.

**§04b of `polyphony-arc.html` drew an earlier version** of the gate as a whole-form block at
the bottom of the form. It is superseded by §04c and is being replaced — noted because a mock
with two answers in it is worse than a mock with none.

## Standing decisions

- **Nothing a scene decides is applied on its own.** Accepting is a deliberate act, and
  refusing one is not a rejection of the scene — it is how you write the person who didn't
  go along with what happened to them. That asymmetry is the whole feature.
- **Every proposal carries a Because line and its provenance.** Which scene, which beat.
  Without it a proposal is an assertion about somebody you wrote, from nowhere.
- **The gate is per-cast, not per-backlog.** Nineteen proposals pending on a different
  campaign do not block opening a scene with two — otherwise the review queue becomes a
  reason not to play. It is per-cast **within** a campaign too: `SceneGate.check/3` looks
  only at the characters in the scene being opened, so nineteen pending across ten people
  do not block a two-hander whose two are clear. The library row counts the whole backlog
  and is therefore an upper bound rather than the same number — `library.md` says so now,
  having claimed the opposite.
- **The world's arc gates every scene, whoever is in it.** The one thing that is *not*
  per-cast: pending world-arc proposals block any scene in the campaign, because a world
  fact is true for everybody and there is no cast small enough to duck it. Worth knowing
  before designing the blocked state — the reason a scene is gated may name nobody in it.
- **The gate is met on the row, not at the submit button.** A cast row carries its own
  character's arc state and its own fix, so you learn somebody is behind the moment you add
  them rather than after writing a premise and picking four other people. A gate discovered
  at the submit button is a gate that feels like a trap. Reviewing happens **in place** —
  expanding a row shows the real cards, not summaries of them, with the same accept, edit and
  reject controls as this screen. It is the same component in all three places you cast
  somebody: scene setup, adding someone mid-scene, and admitting a Director proposal.
- **Accepting everything is the intended fast path, and the only one.** The gate exists to
  keep a character's sheet consistent with their story, not to force careful reading —
  somebody in a hurry taps *Accept all* on the row and still gets a sheet that matches what
  happened. There is deliberately **no second escape hatch**: no open-anyway, no dismiss, no
  remind-me-later. Accept-all without reading already is one.

  The **failure** case is where an escape hatch is least defensible: arc extraction and turn
  generation call the same provider, so a row that can't extract is evidence the scene can't
  run. Letting somebody past would move the failure to one beat after they committed to
  playing.
- **The author can propose too, and their proposals are the same object.** Extraction says
  what a scene concluded; it does not say what it missed, and the person best placed to
  notice a miss is the one reading the things it caught. An authored entry takes the same
  card, the same accept-or-refuse, and the same place in the history.

  **The author and the *Because* line answer different questions.** *Who says so* is the
  author; *what in the story made this true* is the Because. An authored entry always carries
  an author and **may** carry a Because — and usually should, because the common case is not
  invention but recording a consequence the scene had and did not dramatise. A character who
  reacts off-screen to a bell nobody watched them hear has a perfectly good reason, and it
  belongs in the same line as every other reason. An authored entry with a Because reads
  exactly like an extracted one with a name on it, which is the intent: somebody reading a
  history a year later needs to know **why** each thing became true and rarely needs to know
  which system noticed it.

  **An authored entry is not pre-accepted.** It is a proposal against the sheet like any
  other, because the alternative is a second way for a sheet to change and the whole feature
  is that there is only one.
- **A line that gives is a change of state, not a change of value.** A refusal or compulsion
  written as *not until…* carries a condition and a consequence written in advance. When the
  condition is met, nothing is edited — the waiting consequence becomes true. That is a
  fourth operation alongside add, change and remove, and it is the most consequential thing
  that happens to a boundary, so it is named rather than folded into *change*.

  **Three things can satisfy a line, and they make different claims about what already
  happened.** The written condition being met **in play** is the only one that has already
  happened on screen: she acted on it, and review decides whether it becomes permanent rather
  than scene-local. That case, and only that case, takes **True / Not yet** — you cannot
  un-play it. The **Director** proposing that a scene broke a line its written condition
  didn't cover, and the **author** proposing one by hand, have both happened nowhere yet;
  they are ordinary proposals and take **True / Edit / No**.

  When the Director proposes past a written condition, the card **shows that condition,
  struck through and marked unmet**. The author needs to see their own rule being gone past
  rather than silently reinterpreted, and a card citing a condition that never fired reads as
  the trigger system misfiring.
- **Concealment is what the audience says, not a flag beside it.** Every fact, rule and
  entry carries an audience and nothing else. It is **secret when the audience is not the
  default** — for a character, anyone besides her; for the world, anything short of everyone.
  The defaults are opposite because the subjects are: a person's inner life starts private
  and a world's facts start shared. Deriving the treatment rather than storing it means a
  fact marked secret with an empty audience, or an audience with the mark left off, cannot be
  represented at all. See `sheet_editor.md` and `bible_editor.md`, which take the same edit.
- **A group change is one card, not one per member.** It is really one proposal against the
  template plus one per current member; a group of twelve would otherwise flood the queue
  from a change nobody made twelve times.

## States

### `proposals` — What a scene decided about somebody

The working state: cards, each with its Because line, accept and reject.

A card says what it would change, what it changes it **from**, and what in the scene caused
it — the last being what makes accepting quick, since you can check the reasoning without
rereading the scene.

**Three action sets, and which one a card gets is a claim about what has already happened.**

- **True / Edit / No** — the ordinary set. A new fact, a field being replaced, a
  relationship, an authored entry of any kind, and a line the Director proposes past its
  written condition. Nothing has happened yet; you are deciding whether it will.
- **True / Not yet** — a line that **gave in play**. The gate already resolved it, so
  refusing means it stays scene-local rather than never having occurred. There is nothing to
  edit and no way to un-play it.
- **True / Only who was there** — a world fact proposed as **common knowledge**. The refusal
  narrows the audience rather than rejecting the fact; the thing is true either way and the
  question is who it reached. See `world_common_knowledge`.

Authored cards carry their author where an extracted one carries the engine, and are
otherwise identical.

### `nothing_pending` — A character the scene had nothing to say about

Normal, and frequent. See the per-cast standing decision.

### `editing` — Correcting a proposal before taking it

Rather than accepting or rejecting it whole. This is the precedent the authoring review
panel is meant to copy.

### `world_arc` — The world tab

A **global** fact reaches everywhere; a **local** one reaches only its scene's location.
Which is why the scope is a control here rather than an assumption baked into the proposal.

### `group_fan_out` — A group change, collapsed

One card standing for the template change and one proposal per current member.

### `authoring` — Writing an entry yourself

Reached from the *add an entry* row, which sits last in the list of proposals wherever they
are shown — on this screen and in a cast row's expansion. Both, deliberately: it is one
component, and an affordance that exists in one of two identical places is one nobody finds.
Opened from a cast row it arrives with that character and that scene already filled in.

**What changes** is a dropdown rather than a fixed shape: a fact, temperament, cover, a
refusal, a compulsion, a relationship. It uses the same switchable pill the perspective
control does. Refusal and compulsion carry the left-rule the sheet gives them, so the two
directions are distinguishable before you pick one.

**The current value is shown for whatever is picked, struck through.** Most authored entries
are revisions rather than replacements, and editing something you can't see is how you
overwrite it by accident.

**Why**, optionally — the same *Because* line an extracted proposal carries. Offered rather
than demanded: an author correcting their own earlier writing has nothing to cite, while an
author recording what a scene did off-screen has the best reason on the card.

**When it became true.** Three answers, and they are not degrees of the same thing. *Always
true* corrects the person you originally wrote and sits before everything play has done — her
history stays and applies on top. *In a scene* attaches to a closed scene and takes its place
in the timeline there. *Just now* is a change made off-screen: true from now, tied to no
scene. The last is why the scene is optional rather than required — authors write between
sessions, and a change decided at the kitchen table is not less real than one a scene
concluded, but it is not *always true* either, and collapsing the two would rewrite history
every time somebody changed their mind about the present.

This state is the simple case: a field holding **one value**, like temperament or cover.
Nothing to pick and one thing to write.

### `authoring_list` — A field that holds many

Facts, and anything else that is a list. *Which one* has to be answerable before *what about
it*, so an operation comes first: **add**, **change**, **remove**.

*Add* has no previous value to show. *Change* and *remove* show the list, and once an item is
picked, *change* strikes it through above its replacement.

**Removing is not deleting.** It stops being true from here and stays in the history, so
scenes written while it was true do not change. The state says so, because removing something
from a character reads like editing the past and isn't.

A fact also carries **always in mind** — whether she carries it into every turn — and an
**audience**. The two are orthogonal and the form never implies one follows from the other: a
woman can have a secret she never thinks about, which is the case the sheet calls the one
that needed solving.

### `authoring_line` — A refusal or a compulsion

A line is **never** or **earnable**. A *never* is a hard line whatever happens. An earnable
one carries an **until** — the condition that would move it — and an **and then**, what she
does once it has. Adding one is where that pair is set.

Four operations here rather than three: **add**, **change**, **satisfied**, **remove**.

**Satisfied** shows the condition and the consequence already written for it, and asks only
whether the condition was met. The consequence is editable if the moment wants something
else, but it is not invented here — that is what makes satisfaction its own operation.

A *never* has no condition, so satisfying it is offered and **disabled** rather than absent.
An operation that disappears reads as a bug, and why it is unavailable is a fact about that
line worth seeing.

### `authoring_relationship` — Directional, so you pick a direction

A relationship is how **she** regards **him**, and the interesting cases are the ones where
the two directions don't match. So the picker lists **directions, not people**: *Wren →
Aldous* and *Aldous → Wren* are separate rows, four rows for two people. Changing what she
thinks of him must not touch what he thinks of her, and a picker listing names invites
exactly that.

*Add* takes a target and a regard, and names somebody who doesn't exist yet the way the sheet
does — they join the campaign as a walk-on and stay unwritten until needed.

*Remove* ends one direction and says so: what he thinks of her is untouched and stays on his
sheet. Without that sentence, removing a direction reads as severing a relationship.

### `authoring_world` — The world's own entries

The same form with a shorter dropdown and one control more. A world has **a fact or a rule** —
no temperament, no cover, no lines to hold — and every entry carries **who knows**, which is
the audience picker doing the job it does on a secret.

A world's default audience is **everyone**, so narrowing is what marks an entry rather than
widening. That is the opposite direction from a character and the same rule underneath: the
treatment follows the audience differing from the default.

Rules are what triggers will read once triggers exist. A rule can be narrowed like anything
else — a rule the town doesn't know is how a world keeps a secret.

### `world_common_knowledge` — A fact proposed as everyone's

Its own state because its **actions differ**: **True / Only who was there**. The refusal
narrows the audience rather than rejecting the fact, which no other card does.

What accepting means is worth saying on the card: anyone off-screen is told this the next
time they turn up, and reacts to it on the page rather than arriving already used to it. That
is the off-screen problem being solved by delivery rather than by extrapolation.

*Everyone* means common knowledge with no scoping — not *the whole town*, which would be a
location audience once locations exist.
