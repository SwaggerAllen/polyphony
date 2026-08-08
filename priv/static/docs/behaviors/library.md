# Library

<!-- rev: 2 -->

| | |
|---|---|
| Route | `/library` |
| Storybook | Screens → Library |
| Code | `PolyphonyWeb.Screens.Library`, `PolyphonyWeb.LibraryLive` |

Your shelf. Everything you have written or are reading, in tabs: campaigns, people, worlds,
groups, what you're reading, and what you have filed or binned.

## Standing decisions

- **The people you wrote are held apart from the people a story invented.** This is the
  screen's one real idea. A cast list that mixes an authored lead with forty walk-ons reads
  as clutter, and deleting clutter is how somebody loses a character they meant to keep.
- **Destructive actions live in a row's overflow menu, never on the row.** The shelf should
  read as a list of work, not a list of ways to lose it.
- **Archive and trash are different things and are shown apart.** Archiving is recoverable
  with one button and no confirmation, because nothing was ever at risk. Trash is on a clock,
  and the only irreversible button in the product lives on the trash shelf where the
  countdown is visible.
- **Render everything until structure stops doing the work.** Search and filters arrive when
  a library gets long, not before — a search box over eleven items is furniture.

## States

### `campaigns` — The shelf

A campaign row carries what you need to pick it back up: where it is in its life, its world
and size, and how many arc proposals are waiting.

That last number is an **upper bound** on what the scene gate will stop you with, not the same
number — this document used to claim they were identical and they are not.
`Campaigns.pending_review/2` counts every proposal about the campaign's whole cast plus its
world; `SceneGate.check/3` counts only the characters *in the scene you are opening*, plus the
same world total. Opening a two-hander whose two have nothing pending gates clean while the
row still reads nineteen.

The bound is the useful half and is worth keeping: **nothing waiting means nothing will stop
you**, and the row is never lower than the gate. What it cannot promise is the reverse, so it
should not be read as a countdown to a scene you can open.

### `first_run` — Nothing written yet

One button. Deliberately **no** explanation of worlds, characters and groups — you do not
need the entity model to start, and the campaign flow introduces each piece at the moment it
matters.

### `people` — Cast and walk-ons

The standing decision above, on screen: authored people first, walk-ons in their own section.

### `no_walk_ons` — Before any story invented anybody

The walk-on section collapses rather than showing an empty heading. A heading for a thing you
have none of is a question nobody asked.

### `searching` — Filtering by name and tier

What the shelf becomes once it is long enough to need it.

### `reading` — Somebody else's story, on your shelf

A published campaign you are partway through. The row carries the author and **which
perspective you were reading in** — a published story is read *as* somebody, and picking that
back up is the entire promise of a bookmark.

### `archive` — Filed and binned

Both on one tab, visibly different. See the standing decision.

### `row_menu_open` — A row's overflow menu

Where rename, archive, trash and the rest live.
