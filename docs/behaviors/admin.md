# Moderation

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/admin` |
| Storybook | Screens → Moderation |
| Code | `PolyphonyWeb.Screens.Admin`, `PolyphonyWeb.AdminLive` |

An internal tool for people making judgement calls under time pressure, which means
**density is fine and ambiguity isn't**. Five tabs: what's waiting, what was decided, who is
suspended, the invites, and who can do all of this.

## Standing decisions

- **Child safety is its own lane, always first.** Not a filter on a general queue — a
  separate list, because the alternative is the one report that cannot wait sitting under
  forty about spam. Oldest first inside each lane.
- **Content and people are different objects.** Taking down a snapshot and suspending an
  account have different consequences and different reversals. Never one button, never the
  same row.
- **Reading what wasn't published is asked for out loud.** A moderator has to see private
  thoughts, whispers and sheets in order to judge, and that is a real privilege — so the
  screen says what it means, asks *why* first, and records it with their name. Nobody types a
  reason forty times a day for something they don't need. The banner stays up for as long as
  the unpublished material is on screen, because an access that looks like ordinary reading
  is one nobody remembers making.
- **A take-down opens a review lane rather than firing a cascade.** It takes the public copy,
  the author's own, and puts every descendant fork in front of a person — a fork may have
  diverged twenty scenes past anything objectionable, and deleting it blind destroys work
  that contains none of what was reported.
- **Every account action is reversible.** A suspension can be lifted and an admin can be made
  ordinary again. An indefinite suspension with no way back is a deletion nobody agreed to,
  and an admin promoted by mistake used to be permanent.
- **Every line naming a person or an artifact arrives already resolved.** Not a design rule
  so much as a consequence of the screen's shape: four lists resolving a name per row is an
  N+1 across the whole page.

## States

### `queue` — What's waiting

The child-safety lane on top, then forks under review, then everything else.

### `queue_empty` — Nothing waiting

Which is what this screen looks like nearly all the time. It says how the queue orders itself
rather than leaving a blank sheet, because that ordering is what a new moderator needs to
know before the first report arrives.

### `fork_lane` — Forks of things taken down

See the standing decision. Each one is *leave it up* or *take it down too*, decided by a
person.

### `one_report` — Reading one

Everything needed to decide in a single read: who it is about, what the reporter said, and
both directions of the account's history.

### `history` — The account's history, both ways

Reports against them and reports they made. Somebody whose own reports are nearly all
dismissed is a signal too, and a queue that only ever looks at the accused cannot see it.

### `unlocking` — Asking for the bypass

The reason field. See the standing decision.

### `viewed` — Granted, and written down

With the banner up.

### `takedown_spreads` — A take-down with descendants

The confirmation **names what is destroyed** rather than saying "a campaign". The weight of
the action should be visible at the moment of taking it.

### `decided` — What was decided, and what was done

The resolved reports, and the audit trail beneath them. Privilege use is tinted: reading an
unpublished perspective is the entry most likely to matter later and least likely to be
looked for.

### `suspended` — Who is suspended

For how long, how much of theirs went dark, and the button to lift it.

### `invites` — The door

Two buttons rather than a switch beside one, because a single-use and a reusable invite are
different objects once minted. A reusable one is a standing hole in the gate for as long as
it exists, so the row says so and it can be closed.

### `invites_empty` — None minted

Worth saying why the list exists at all, since invite-only is a decision about this stage of
the project rather than a permanent shape.

### `admins` — Who can do all of this

The first account is pinned — exactly one superadmin, minted at first sign-up and never
assignable. Everybody else can be made ordinary again.
