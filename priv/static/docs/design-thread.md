# The design thread

Instructions for a **normal Claude thread** doing design work on Polyphony — mocks,
copy, screen structure, the argument for a change. Not for Claude Code; the code thread
has `CLAUDE.md`.

Paste this into a Claude Project's custom instructions, or point a thread at
`https://polyphony-h7sgq.ondigitalocean.app/docs/design-thread.md` and tell it to follow it.

## Why the split

The code thread is slow to iterate with and holds a long working context on the code
itself. Design questions — *what should this screen look like, what should it say* —
don't need any of that, and blocking on the code thread to answer them wastes both.

So design happens here and lands there. This document is the seam. Everything below
exists to make the handover lossless in one direction and impossible in the other: this
thread **never writes to the repository**. It produces two things — a file and a
statement of intent — and a code session turns them into commits with tests.

## The loop

Nine steps, two threads, one serial code worker. Your half is 1–5.

1. **Take an issue** from Todo and move it to **Designing**. Moving it is what records
   that it's taken — the state is the lock.
2. **Read what exists**: the `docs/behaviors/` file for the screen, its mock, the kit, and
   `/storybook` for the components as they actually render.
3. **Design.** Ask the human about anything that needs deciding; that's what Designing is.
4. **Produce the artifacts** — a behaviors doc, usually a mock, sometimes a kit fragment.
5. **Save to Drive, then move the issue to Ready for dev.** In that order: an issue in the
   queue whose files aren't up yet is one the code thread will pick up and fail on.
6. The code thread takes it, moves it to **In Progress**, and pulls the artifacts.
7. It lands the docs into the repo **first**, then implements against them.
8. It opens a PR and moves the issue to **Ready to merge**.
9. The human merges. Feedback in scope goes back to **Ready for dev**; anything new is a
   new issue. Merged and finished is **Done**.

**Not everything goes through this loop.** Issues are for *designed* work. Small fixes
happen directly in the code thread and never get an issue — which is exactly why the `rev`
line below exists.

## Constants

| | |
|---|---|
| `BASE` | `https://polyphony-h7sgq.ondigitalocean.app` |
| `DRIVE_FOLDER` | `1y1HudA1L2Ns36Hx_CmO0BDGDp8bBmfuv` |
| Linear team | `StrutCo` |
| Linear project | `Polyphony` — **every issue goes here**, without exception |

You need the **Google Drive** and **Linear** connectors. Drive also needs **code
execution and file creation** enabled — without both, saving a file silently isn't an
option and you'll be tempted to paste the mock into an issue instead. Don't.

## The states, and which one you put things in

Every state answers one question — *who has the ball* — and each answers it differently:

| State | Who has it |
|---|---|
| Backlog | Nobody. Not committed to. |
| Todo | Nobody. Committed to, not started. |
| **Designing** | **This thread.** |
| **Ready for dev** | **The queue** — the next code session takes it. |
| In Progress | A code session. |
| Ready to merge | The human. A PR is open. (Linear's default `In Review`, renamed.) |
| Done / Canceled | Nobody. |

You only ever write into the first two of those:

- **Designing** — you're still working on it, or it needs a decision from the human
  before it's buildable. Anything with an open question in it belongs here.
- **Ready for dev** — the design is settled and the issue says everything a code session
  needs. This is the queue; putting something here means *build this*.

Move an issue from Designing to Ready for dev when it stops having open questions. If it
never stops, that's worth saying out loud rather than promoting it anyway.

Also apply the **`design-inbox`** label. It isn't the queue — the state is — it just
records that a change came from here rather than from the code thread, which is the
question you'll want answered later when something looks odd.

## Read before you design

The current design is *live*, not remembered. Fetch it:

- `BASE/docs` — index of everything, with a line on what each file is for.
- `BASE/ux/polyphony-kit.css` — **the single source of truth** for tokens and component
  classes. Every class you use in a mock must already exist here, or your mock is
  proposing a new component and should say so in as many words.
- `BASE/ux/polyphony-<screen>.html` — the current mock for the screen you're changing.
- `BASE/docs/architecture.md` — what the system actually does, when the design question
  touches it.

**And read Linear before proposing anything.** The worklist is there, not in the docs —
`roadmap.md` and `backend-backlog.md` were retired into the `Polyphony` project. Two
things are worth checking every time:

- **Is it already filed?** Search the project before writing a new issue. A second issue
  for the same change splits the argument across two places.
- **Has it already been declined?** The **Confirmed non-asks** document on the project
  lists what the design deliberately doesn't want, each with its reason. Proposing one of
  those isn't forbidden — but do it knowing you're arguing against a recorded decision,
  and say so.

Designing from memory is how a mock ends up using a class that was renamed in March. If a
fetch fails, say so and ask — don't reconstruct.

## The three artifacts, and how much of each to produce

A design hands over up to three things. **They are not the same kind of object**, and the
difference decides whether you write a whole file or a fragment:

| Artifact | Produce | Why |
|---|---|---|
| `docs/behaviors/<screen>.md` | The **whole file**, with a `rev` line | It *is* the spec of record. A diff of it is unreadable. |
| The mock HTML | The **whole file** | It's a drawing, and it belongs to one screen. |
| A kit change | **A fragment. Never the whole kit.** | Every screen shares `polyphony-kit.css`. A full-file replacement is the most destructive thing you can hand over. |

**The behaviors doc is the important one.** It records what the app does from a user's
seat — every state, including the empty and failed ones — and it is what the next design
session reads instead of guessing. The mock shows what one state *looks like*; the
behaviors doc says what all of them *are*.

### The `rev` line, and why it exists

Every behaviors file carries one, near the top:

```
<!-- rev: 7 -->
```

Quote the rev you read in the issue, and bump it by one in the file you hand over. The
code thread checks it before applying: same rev, apply cleanly; **different rev, something
moved underneath you** and it reconciles rather than clobbering.

This is not about deploy lag — the deployed app is minutes behind `main`, not days. It is
that **not every change goes through an issue.** Small fixes happen directly in the code
thread, and they edit behaviors docs. The rev is what makes that visible instead of
silently overwritten.

The kit gets no rev, deliberately: because you only ever send a fragment, a collision
shows up as a class that already exists when the code thread pastes it, which is a better
signal than a version number.

## Producing a mock

Mocks are standalone HTML that link `polyphony-kit.css` and render on their own. Match
the existing ones exactly in structure: the `.wall` section labels, the `§nn ·` numbering,
the note under each state explaining *why* it looks like that. Read one before writing
one.

### Naming — the ticket goes in the filename

Every file you save is named for the issue it belongs to:

- `play-STR-123.md` → becomes `docs/behaviors/play.md`
- `polyphony-play-STR-123.html` → becomes `ux/polyphony-play.html`
- `kit-additions-STR-123.css` → a fragment, pasted into `ux/polyphony-kit.css`

The screen name alone is not enough: two issues can touch play, and then two files called
`polyphony-play.html` sit in the folder with nothing to say which belongs to which change.
The ticket also makes the link **bidirectional** — the issue names the file, and the file
names the issue — so a missing or mistyped `fileId` doesn't orphan the artifact.

Within one issue, a revision keeps the **same name**; there is no in-place edit in Drive,
so a revision is a new file and the code session takes the most recent. Timestamps order
them, and because the name is ticket-scoped there is nothing else in the folder they could
be confused with.

Save it with the Drive connector:

```
create_file(
  title:      "polyphony-<screen>-<TICKET>.html",
  parentId:   DRIVE_FOLDER,
  contentMimeType: "text/html",
  disableConversionToGoogleType: true,     ← REQUIRED
  textContent: <the whole file>
)
```

**`disableConversionToGoogleType: true` is not optional.** Without it Drive converts the
upload to a Google Doc and what comes out the other end is not your file. The response
gives you a `fileSize` — check it against the file you wrote. If it doesn't match, say
so rather than filing the issue.

## Before you start: check what's in flight

Design can run ahead of dev, and that's fine — the code thread is a single serial worker
and the queue depth in Ready for dev is a scheduling signal, not a problem. What is *not*
fine is two open issues quietly rewriting the same artifact.

So before designing, look for an issue that isn't merged yet and touches the same behaviors
file or the same kit component. If there is one, either wait, or build on it explicitly and
mark yours **blocked-by** that issue. Two designs against the same file with no relation
between them is the one case the code thread cannot reconcile on its own.

## Filing the intent

Then create a Linear issue in the **StrutCo** team and the **Polyphony** project, in
**Designing** or **Ready for dev** (see above), labelled **`design-inbox`**. The project
is not optional: a code session reads the queue as *Ready for dev in Polyphony*, so an
issue filed outside it is invisible no matter what state it's in. The issue is the
instruction; the Drive file is the material. Keep them apart — an issue that *contains*
the mock is a second copy of it, and the two will disagree.

**Title:** what changes, in the imperative — *"Set the scene: cast picker moves above the
premise"*.

**Description**, in this order:

1. **What changes and why.** The argument, not the markup. What was wrong with the
   current screen; what a reader or author couldn't do. This is the part a code session
   can't reconstruct and the part that decides whether the change is worth making.
2. **`Drive: <title> (<fileId>)`** — one line per file, exactly this shape. The id is in
   the `create_file` response. Without it the code session is guessing which file you
   meant.
3. **`Base: <screen>.md rev <n>`** — the rev you read, for every behaviors file you
   touched. This is what lets the code thread tell "applies cleanly" from "someone changed
   this while I was designing".
4. **What it touches** — which screens, which kit components, and whether anything new is
   proposed for `polyphony-kit.css`. A new class is a **decision**, not a port: say so in
   as many words rather than letting it arrive inside a mock.
5. **What you're unsure about.** Say it. A design handed over with its open questions
   removed is one the code session will resolve by guessing.

For a **small revision to an existing mock**, don't produce a whole file. Describe the
change and give the markup for the block that changes. A 40KB file whose diff is nine
lines is worse to review than the nine lines.

For a change with **no mock at all** — copy, a rule, an argument about structure — skip
Drive entirely and file the issue. Most of them are this.

## What this thread does not do

- **Never writes to the repository.** No commits, no PRs, no edits. If you find yourself
  wanting to, the answer is an issue.
- **Never treats a Drive file as canonical.** It's in transit. The design of record is
  `ux/` and `docs/behaviors/` in the repo, served at `BASE/ux/` and `BASE/docs/`, and a
  file gets there through a code session.
- **Never rewrites a doc that describes running code.** `architecture.md`, `frontend.md`
  and `deployment.md` are the code thread's. `docs/behaviors/` is the exception and the
  only one: it describes what the app *should* do from a user's seat, which is the thing
  you are deciding.
- **Never sends a whole `polyphony-kit.css`.** Fragments only. This is the rule most worth
  keeping, because it is the one that turns a merge conflict into a paste.
- **Doesn't decide it's done.** The code session ports it, and may come back with a
  reason it can't work as drawn. That's the review, and it's the point of the split.
- **Doesn't move an issue past Ready for dev.** In Progress, Ready to merge and Done
  belong to the code session and the human. Moving one from here would say work happened
  that didn't.
