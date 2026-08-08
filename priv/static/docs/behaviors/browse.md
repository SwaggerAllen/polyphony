# Browse

<!-- rev: 2 -->

| | |
|---|---|
| Route | `/browse` |
| Storybook | Screens → Browse |
| Code | `PolyphonyWeb.Screens.Browse`, `PolyphonyWeb.BrowseLive` |

Published stories, and reading one. Two jobs on one route: the shelf of what other people
have published, and a story's front page once you pick one.

## Standing decisions

- **Reading a campaign means choosing whose story it is.** *How you can read it* — which
  heads the author granted, and whether a spectator read is offered at all — comes before
  anything else on a front page. It is the author's content decision, not a display option.
- **A publication is a frozen snapshot.** Reading never touches the author's live campaign,
  a report targets the snapshot, and a take-down therefore never reaches the original.
- **A scene no granted perspective can reach stays in the contents, marked.** Silently
  omitting it would make the story look shorter than it is. The gap is a fact about the
  publication, not an error, and the author was warned about it when they published.
- **Forks group under the story they came from.** Three forks share a title until somebody
  renames one, and a flat list of those reads as duplicates of the same thing.
- **An unlisted story needs its link, here as much as anywhere.** *Unlisted* means reachable
  by the URL somebody was sent and not otherwise, so arriving without the token reads
  exactly like arriving at a story that was never published — see `taken_down`. Saying
  *you need the link* instead would confirm that the id names something somebody shared,
  which is the fact being kept. The link opens the front page and every scene inside it; a
  reader who came in that way keeps their footing for the whole visit without the token
  reappearing in the address bar at every step.
- **You may take a copy of anything you may read.** Not only what is listed: a world shared
  by link is a world somebody meant you to have. What you may *not* read you may not copy —
  taking a copy is reading it and keeping it, so it cannot be the looser of the two.

## States

### `listing` — What's been published

The shelf, with forks nested under their origin.

### `nothing_published` — An empty shelf

Reachable on a fresh install and on a quiet week. It has to say something rather than render
as a blank page.

### `front_page` — A story's front page

What it is, who wrote it, and how you can read it. See the standing decision.

### `start_reading` — Never opened this one

*Start reading*, into the first scene.

### `carry_on` — Partway through

The shelf promises exactly one thing — that you can get back to where you were — and this is
where it is kept: the scene, and the perspective you were in.

### `bookmark_gone` — The scene you were in is no longer published

Republishing replaces the copy somebody was in the middle of, which is the one place that
trade becomes visible. The bookmark falls back to the start rather than stranding the reader
on a link into nothing.

### `not_shared` — A scene nobody granted can read

In the contents, marked. See the standing decision.

### `nobody_shared` — Published with no perspectives at all

There is no way into this story. Saying so plainly beats a front page that looks broken —
and it is a real state, because publishing with spectator off and no heads ticked is
possible.

### `taken_down` — The story is gone

Unpublished by the author or taken down by a moderator. Somebody arriving on a link they were
sent gets an answer rather than a 404.

Three situations reach this one screen and only one of them is announced. A moderated story
says so, because its author follows the same link and a silent disappearance is worse than
the news. An unpublished story and an **unlisted story opened without its link** both give
the same neutral answer — *this link doesn't lead anywhere any more* — because telling them
apart would tell a stranger which ids are stories.

### `reporting` — Reporting something

This screen is where you encounter what another person wrote, which is the whole test for
where reporting has to be reachable. The report targets the frozen snapshot.
