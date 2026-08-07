# Behaviors

<!-- rev: 1 -->

One file per screen, describing what it does **from the seat of the person using it**.
Not markup, not modules, not why the code is shaped the way it is — that is
`architecture.md` and `frontend.md`. This is what a reader, an author or a moderator can
do, what they see when there is nothing to see, and which of those choices are decisions
somebody argued for rather than accidents nobody revisited.

These files exist so that a **design change has somewhere to land before it has any code**.
The design thread (`../design-thread.md`) reads them, proposes against them, and cites the
`rev` it read; a code session lands the changed doc first and implements against it.

## What is and isn't the source of truth

**`/storybook` is.** Every screen, every state, rendered by the real components — plus the
tests that pin the behavior. When a file here and storybook disagree, storybook is right
and this file is stale.

A behaviors doc is the *readable narrative* of that: the argument you cannot see in a
screenshot. It is worth writing down precisely because it is the part that gets lost — a
picture shows that walk-ons collapse behind a count, and says nothing about why mixing them
with the cast is how somebody deletes a character they meant to keep.

## The shape of a file

```markdown
# Play

<!-- rev: 3 -->

| | |
|---|---|
| Route | `/play/:scene_id` |
| Storybook | Screens → Play |
| Code | `PolyphonyWeb.Screens.Play`, `PolyphonyWeb.PlayLive` |

One paragraph: whose screen it is and what it is for.

## Standing decisions
…the two or three things that must not be changed without arguing with them.

## States
### `stage` — Omniscient play
…one section per storybook variation, named by its id.
```

**Every state section is named for a storybook variation, and the two sets must match
exactly.** `BehaviorsDocTest` fails when they don't — so a state added to a screen without
a paragraph, or a paragraph describing a state nobody can look at, is a failing build
rather than a slow drift. That check is the whole reason to trust these files.

## The `rev` line

```
<!-- rev: 7 -->
```

Bump it whenever the file changes, including for a small fix made in the code thread with
no ticket behind it. It is **not** a merge mechanism — a design fragment that no longer
fits is its own signal. It is provenance, and it answers one question: *what was the design
reasoning about?* Months later, when the design and the app disagree, that is the only
record of which one moved.

Undesigned changes are exactly the ones no issue warns anybody about, which is why the
counter matters more for those than for the ones that arrive with a ticket.

## Which file does a behavior go in

One file per **screen**, named for its `PolyphonyWeb.Screens.*` module. A behavior that
lives on more than one screen gets its own file only once it genuinely exists in more than
one place — a shared file written in anticipation is a file nobody updates.

Today exactly one qualifies: the **perspective control**, which appears on play, the
campaign's world tab and the published reader, and has to behave identically on all three.
It is described in `play.md` and cross-referenced from the others, and it becomes its own
file the moment a fourth screen wants it.

## Files

| File | The screen |
|---|---|
| `home.md` | The landing page — the only screen whose job is to explain what this is. |
| `login.md` | Signing in. Magic link, no passwords. |
| `signup.md` | Making an account, behind an invite. |
| `resume.md` | Coming back on a remembered device. |
| `share.md` | An unlisted link to one world or character. |
| `play.md` | A scene as it happens. The screen the product is for. |
| `library.md` | Your shelf: campaigns, people, worlds, groups, what you're reading. |
| `browse.md` | Published stories, and reading one. |
| `campaign.md` | A campaign's cast, world, premise, scenes and publication. |
| `sheet_editor.md` | Writing a character. |
| `bible_editor.md` | Writing a world. |
| `group_editor.md` | Writing a group — the thing a secret can point at. |
| `arc_review.md` | What play proposed about your people, waiting on you. |
| `settings.md` | The account: spend, caps, consent, deletion. |
| `admin.md` | Moderation. |
