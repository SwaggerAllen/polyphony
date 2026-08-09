# Browse

<!-- rev: 5 -->

| | |
|---|---|
| Route | `/browse` |
| Storybook | Screens → Browse |
| Code | `PolyphonyWeb.Screens.Browse`, `PolyphonyWeb.BrowseLive` |

Published stories, and reading one. **Three** jobs on one route: the shelf of what other
people have published, a story's front page once you pick one, and the reader itself. They
share a screen because they are one continuous act — you don't navigate to a reader, you
start reading.

The reading half is the point of the other two. Publishing worked for a long time and
produced nothing anybody could read; this is where a published campaign becomes a thing a
stranger can sit down with.

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
- **A bookmark stands in for the link.** Somebody already reading a story keeps reading it
  when the author narrows it from public to unlisted — narrowing who can *find* something
  is not evicting the people inside, and the reading shelf makes the same promise. Pulling
  it back to private is the real withdrawal, and that shuts the door on everyone: the story
  goes as unreachable here as it reads on the shelf.
- **You may take a copy of anything you may read.** Not only what is listed: a world shared
  by link is a world somebody meant you to have. What you may *not* read you may not copy —
  taking a copy is reading it and keeping it, so it cannot be the looser of the two.
- **An action that isn't available isn't shown.** No greyed-out buttons, no *request access*,
  no *upgrade*. A story shared to be read and not continued is **not a locked door — it is a
  different offer**, and the difference matters: a disabled control tells a reader they are
  the wrong sort of person, while an absent one lets the page say what it *does* offer. The
  page names what was shared instead, in the author's terms, and stops there.
- **People can't be taken on their own.** Characters travel only inside a fork. A character
  lifted out of their campaign has no history and knows nobody — the arc that makes them
  worth having is a record of scenes that came with a world and a cast, and copying the sheet
  alone would produce a stranger wearing a name. Three appetites are legitimate — carry the
  story on, borrow the setting, keep the person — and the product answers the first two.
- **The reader is the play screen with a different bottom bar.** Same header, same
  perspective control, same transcript, same beat rules — only the composer is replaced, by
  scene navigation. It takes the *page* register, because it isn't an authoring surface, it
  is a way of reading. Anything that drifts between the two is a bug in whichever one moved:
  the perspective control in particular is defined on play and appears here unchanged, and
  drift between its treatments was the worst consistency failure of the design pass.
- **Two different kinds of empty, and they must not be said the same way.** *Sable wasn't
  here* is a fact about the reader's **perspective** and has a way out — switch heads, or
  carry on. *This one isn't shared* is a fact about the **publication** and has none. Both
  are shown rather than skipped: silently dropping a scene would make the numbering lie and
  the story jump.
- **Reading never hits a wall; only the actions do.** A signed-out visitor gets the whole
  story. Keeping your place, taking a copy, and reading it as someone in it are the three
  things that need an account, and that is said once, plainly, under the pager — not as a
  gate in front of the text.
- **A reading position is a URL.** Which story, which scene, which perspective, all three in
  the address bar. A position you can't link to isn't one you can come back to, and those are
  exactly the three things the bookmark stores. The place is written **on arrival** rather
  than on leaving, because the reader who closes the tab mid-scene is the one who needs it.

## States

### `listing` — What's been published

The shelf, with forks nested under their origin.

### `nothing_published` — An empty shelf

Reachable on a fresh install and on a quiet week. It has to say something rather than render
as a blank page.

### `front_page` — A story's front page

What it is, who wrote it, how you can read it, and **what you may take away with you**. See
the standing decisions.

The take actions are computed from the snapshot rather than offered and refused: *make it
mine* appears when the publication is forkable, *use this world* when the snapshot embeds a
bible, and reporting always. Which of them a reader sees is therefore a description of what
the author shared, and the four combinations are the four `taking*` states below.

### `start_reading` — Never opened this one

*Start reading*, into the first scene.

### `carry_on` — Partway through

The shelf promises exactly one thing — that you can get back to where you were — and this is
where it is kept: the scene, and the perspective you were in.

### `bookmark_gone` — The scene you were in is no longer published

Republishing replaces the copy somebody was in the middle of, which is the one place that
trade becomes visible. The bookmark falls back to the start rather than stranding the reader
on a link into nothing.

### `taking` — Carry this on yourself

The fork offer, and it is explicit about scale because a fork is not a bookmark: **a copy of
everything** — the world, every person, and everything that happened to them. It picks up
where this leaves off.

Two sentences do the real work, and neither should be cut for length. *Nothing you do touches
the original* answers the fear that taking something damages it. *Their version stays exactly
as it is; yours becomes a different story from the first thing you change* answers the
opposite fear, that a fork is a shared document — it is the moment somebody understands they
are getting a divergent copy rather than a collaboration.

### `taking_world` — Just the setting

The world on its own, with its cover, offered as a copy into the reader's library.

**You take the whole bible, and none of the arc — which means you get the world as it was
before the story started.** Both halves of that need saying and the second is the one people
will get wrong.

There is no partial copy and no permission tier inside a world: everything the author wrote
comes across, including entries they kept from you while you were reading. What does not come
across is the **arc**, and the arc is everything the campaign changed. Strip it and you are
left with the starting bible — the world at scene one, before anything in the story you just
read happened to it.

That is a feature and it is also a surprise. Somebody who read a story about a city falling
takes home the city standing. The page has to say so, because the alternative is a reader
attaching a world in play and discovering the difference through a Director that has never
heard of the events they remember. **The only way to get the world as the story left it is to
fork the campaign** — that is what a fork carries and this does not. (Prequel handling is
specced and unbuilt; when it lands it is the other answer to this same question.)

The other half is worth a sentence too: a reader who spent an evening not knowing something is
about to own the answer. **The view-as selector is the control for that**, and it is the same
one they were reading with — set it to a character and the bible shows what that character
knows. Somebody who wants the setting without spoiling the story does not need a different
copy; they need to keep reading it the way they were.

The alternative is offered in the same breath — *or take it unread and find out in play* —
which is a real way to use this and not a consolation.

### `taking_not_forkable` — Shared to be read, not continued

The story cannot be forked and the world can be taken. The copy says what the author chose,
in their terms — *shared this to be read, not continued* — and immediately what remains
possible: take the world and write your own people into it.

**No disabled fork control.** See the standing decision. The state's whole job is to read as a
different offer rather than a refusal, and a greyed-out button undoes that in one glance.

### `taking_nothing` — Nothing to take with you

Neither forkable nor carrying a public world. It names both facts in one sentence and offers
the only remaining action, which is to keep reading.

This is the state most at risk of being written as an apology. It should not be. The author
published a story to be read and a reader is reading it; nothing has gone wrong, and the page
should not imply the reader was owed more.

### `reading` — A scene, read as one of the published heads

The reader proper. The story's name is the eyebrow, the scene's title is the title, and the
chevron goes back to the front page rather than into browser history — it is the one link out
of a story that isn't a patch, so it is also the one that has to carry an unlisted reader's
grant with it.

The perspective control names *Reading as*, and it splits into two groups: **who can show you
this**, and **not in this one** — the heads that are published but weren't in this scene,
listed with *wasn't there* rather than removed. Removing them would make the story look like
it has fewer heads than it does; greying them out and saying why is the same information
without the lie. The reader's current perspective stays in the list either way, so nothing
jumps under them when they switch.

The bottom bar is where play's composer would be: the place in the story, and the way on.

### `reading_spectator` — The same scene, nobody's thoughts

Everything said and done, no interiority. Worth its own state rather than being filed as a
perspective option, because this is the difference the product exists for: one scene, two
heads, genuinely different text. It is a property of the projection — what the log gives that
reader — not a display setting the screen applies, and nothing on this screen re-implements
it.

### `reading_not_present` — Read as somebody who wasn't in this scene

A fact about the reader's **perspective**, so it has a way out: switch heads, or carry on.
The copy says what a filtered scene means rather than what the app couldn't do — they found
out about this the way you're about to, afterwards, from someone else.

### `not_shared` — A scene no granted perspective can reach

A fact about the **publication**, so unlike `reading_not_present` it offers nothing to switch
to. It appears twice on purpose: marked in the contents on the front page, and as this screen
if the reader opens it anyway. Silently omitting it would make the story look shorter than it
is, and the author was warned about the gap when they published.

### `reading_who` — Who is this?

Opened from a name in the transcript. A reader meets six names in two pages and had no way to
ask about any of them without leaving the story. It shows that character's **cover** — the
field written to be shown — and never the sheet, half of which is things this reader is
specifically not supposed to know. The same card play uses, asked from the other side.

Opening a new scene closes it: it was about somebody in the scene you left.

### `reading_last_scene` — The end of the story

*That's the end of it*, in place of the pager's Next. To a reader, running out and being
finished are different events and only one of them wants somewhere to go.

### `reading_signed_out` — Reading without an account

The whole story, and one line under the pager naming the three things that need signing in:
keeping your place, taking a copy, and reading it as someone in it. See the standing
decision — the line sits at the point those become relevant, not in front of the text.

### `reading_as_info` — Why the story changes when you switch

The drawer behind the ⓘ on the perspective control, opened from the selector rather than
pushed at anybody. It says the two things a confused reader needs: each of these people knows
different things, **so the story is a different length depending on whose eyes you are
behind**; and switching keeps your place, with things appearing and disappearing being *the
point rather than a fault*.

**No toast on switch.** That gets irritating by the second one, and the explanation belongs
where somebody confused would idiomatically go looking — beside the control that confused
them.

**The control beside it stays a plain native select.** `polyphony-browse.html` §03 draws its
open list as a styled panel, grouped into *who can show you this scene* and *not in this one*,
with absent characters dimmed. **None of that is buildable and the frame comes out.** The
control is a native `<select>`; its open list is drawn by the operating system and cannot be
styled, grouped or dimmed. Drawing one is how the grouping came to be proposed at all.

The closed pill is the whole of the control a mock can show, which is why play and the
campaign's world tab only ever draw that — and it is the strongest form of the identical-
treatment rule, since a control nobody can restyle cannot drift.

Nothing is lost by not warning first. `reading_not_present` already says Halden wasn't there
the moment you pick him, which is when it matters; warning first and explaining second says
the same thing twice.

The ⓘ is therefore the **only** thing the reader adds, and it adds it beside the control
rather than inside it.

This is a **surface-specific affordance, and the only one the perspective control carries.**
See the amendment to `play.md`'s perspective-control section: the control itself is identical
everywhere and that is not negotiable, but what sits beside it may differ, because the thing
needing explanation differs. An author on play is choosing which projection to write as and
nothing is being withheld from them; a reader is being shown a deliberately partial story and
has no way to know that is intended.

### `reconnecting` — The socket dropped and is coming back

The reader is a LiveView and drops like any other, on the screen most likely to be read on a
train. Same treatment as `play.md`'s, and for the same reason: driven by the class LiveView
puts on the container rather than by an assign.

It differs from play's in what it can promise. Play says nothing written is at risk because
reconnecting replays the log; **a reader has nothing at risk in the first place**, so the
sentence is smaller — the story is still there, the page is catching up. Reading position is
a URL, so even a full reload returns to the same place.

### `disconnected` — The socket is gone

Not coming back on its own. Says the page will catch up rather than offering a retry, because
there is nothing here to retry — the transport rather than the fiction, as `play.md` has it.

The pager and the perspective control stop responding, which is the visible consequence and
the thing to say: the text you already have stays readable. A reader who can still read is
much less stranded than a player who cannot act, and this state should not borrow play's
urgency.

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
