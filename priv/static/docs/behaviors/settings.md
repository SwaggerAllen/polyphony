# Settings

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/settings` |
| Storybook | Screens → Settings |
| Code | `PolyphonyWeb.Screens.Settings`, `PolyphonyWeb.SettingsLive` |

The account rather than the work: what you have spent, what you are willing to spend, what
you have consented to, and how to leave.

## Standing decisions

- **Spend is stated as turns remaining, not as a percentage.** Nobody knows what 43% of their
  budget feels like; everybody knows what nine more turns feels like.
- **With nothing to estimate from, the estimate is absent rather than guessed.** A made-up
  number on a new account is worse than a blank, because it will be wrong in a direction
  nobody can predict.
- **The two caps protect against different things and therefore live in different places.**
  A daily cap catches a runaway loop; a per-campaign lifetime cap catches one story eating
  the month. Merging them into one number would lose whichever failure the survivor doesn't
  cover.
- **A refusal always says when.** *No* without *when* reads as a bug — so the username
  cooldown is stated as a date rather than as a rule.
- **A policy update is a task, not a modal.** Blocking a whole account on a document change
  punishes the person who least deserves it.
- **Deletion is a decision on a clock.** Signing back in inside the window takes it all back,
  and the confirmation counts what actually goes.

## States

### `settled` — The ordinary state

Spend as turns remaining, with a per-campaign breakdown. The breakdown attributes a scene's
generations to the campaign that owns the scene, which is how one story eating a month
becomes visible before the cap bites.

### `no_history` — A new account

Nothing to estimate from. See the standing decision.

### `cap_reached` — At the ceiling

The error copy elsewhere in the app has always said *you can raise it in Settings*, so the
control has to actually be here. It was a promise with nothing behind it for a long time.

### `editing_cap` — Raising it

Both caps, in their two places.

### `username_locked` — The handle is on cooldown

Stated as a date.

### `needs_reconsent` — The consent documents moved

A task on the page, not a wall in front of it.

### `confirming_delete` — The confirmation

Counting what actually goes: *three campaigns, two worlds and forty-one characters* rather
than *all your work*, which is easy to skim past.

### `deletion_pending` — Already asked for

The window, and the way back out of it.
