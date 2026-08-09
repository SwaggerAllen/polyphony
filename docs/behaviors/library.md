# Library

<!-- rev: 3 -->

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
- **A section collapses; a tab explains.** `no_walk_ons` hides an empty heading because a
  heading for a thing you have none of is a question nobody asked — but that section sits
  inside a tab with other content on it. A tab is a destination. Arriving somewhere and
  finding nothing under it reads as broken rather than as restraint, so every tab says
  something when it is empty, and says what the tab is *for* rather than that it is empty.

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

### `worlds` — The worlds you've written

One row per world, each carrying whether it is **private or public**, its cover line, and
**how many campaigns were started from it**. That last number is what makes this a shelf rather
than a list, and it counts starts rather than shares: attaching a world copies it, so each of
those campaigns holds its own and none of them share an arc.

A world with nothing past its name still gets a row, marked *never used*. It is not an error
— starting a world and leaving it is how most of them begin — and hiding it would lose the
only copy of a name somebody chose.

### `worlds_empty` — No worlds yet

Reachable with campaigns already on the shelf: a campaign exists before its world is written,
which is what `campaign.md`'s `world_none` describes. So this is not a first-run state and must
not read like one — it is what a brand-new campaign's author sees for as long as it takes them
to write the world, which may be a while.

**No create button.** A world is written inside a campaign, the same as everything else on
this shelf; the tab is where you see what you have, not where you make more. Offering one here
would be a campaign-picker wearing a create button.

The copy says what a world **is** — the setting a story runs on, its rules, its facts, its
tone — and nothing about sharing. Attaching a world copies it, so two campaigns never hold the
same one and their arcs diverge from the moment it lands. Any copy implying a shared world
would be describing something the app deliberately doesn't do.

There is most of a phone screen of room on an empty tab. The copy is given space rather than
crowded under the tab strip: one sentence, wide margins, and the action well clear of it.

### `groups` — The groups you've written

Banded by the campaign each belongs to, because a group belongs to a campaign the way a
character does. The band is what tells two crews of the same name in two campaigns apart.

A row carries how many members it has and how many secrets it holds. The second is the number
that distinguishes them: a group whose facts are all public is a tag rather than a membership.

### `groups_empty` — No groups yet

**The most common state on this tab.** No create button here either, for the same reason as
worlds — and one more besides: a group stays in the campaign it was written in and never
appears in another, so there is nothing this shelf could offer to make.

The copy makes the case rather than reporting a gap: a group saves writing the same person
five times, and gives a secret somewhere to point. A library with no groups is not missing
anything — Quick Build's group switch is off by default, so this is what a perfectly healthy
account looks like for a long time, and the state should not read as a to-do.

Same spacing and the same restraint as `worlds_empty`. Secondary styling on the action in
both, because neither is a task.

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
