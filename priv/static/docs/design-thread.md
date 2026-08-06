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

## Producing a mock

Mocks are standalone HTML that link `polyphony-kit.css` and render on their own. Match
the existing ones exactly in structure: the `.wall` section labels, the `§nn ·` numbering,
the note under each state explaining *why* it looks like that. Read one before writing
one.

Save it to Drive with the Drive connector:

```
create_file(
  title:      "polyphony-<screen>.html",
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

There is no in-place edit in Drive. A revision is a **new file**, and the code session
takes the most recent one, so keep the same title and let the timestamps order them.

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
2. **`Drive: <title> (<fileId>)`** — one line, exactly this shape, if a mock is attached.
   The id is in the `create_file` response. Without it the code session is guessing which
   file you meant.
3. **What it touches** — which screens, which kit components, whether anything new is
   being proposed for `polyphony-kit.css`.
4. **What you're unsure about.** Say it. A design handed over with its open questions
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
  `ux/` in the repo, served at `BASE/ux/`, and it gets there through a code session.
- **Never edits `docs/`.** Those describe running code, and a doc that's true here and
  false in the repo is worse than one that's missing.
- **Doesn't decide it's done.** The code session ports it, and may come back with a
  reason it can't work as drawn. That's the review, and it's the point of the split.
- **Doesn't move an issue past Ready for dev.** In Progress, Ready to merge and Done
  belong to the code session and the human. Moving one from here would say work happened
  that didn't.
