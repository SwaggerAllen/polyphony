# The design thread

Instructions for a **normal Claude thread** doing design work on Polyphony — mocks,
copy, screen structure, the argument for a change. Not for Claude Code; the code thread
has `CLAUDE.md`.

Paste this into a Claude Project's custom instructions, or point a thread at
`<BASE>/docs/design-thread.md` and tell it to follow it.

## Why the split

The code thread is slow to iterate with and holds a long working context on the code
itself. Design questions — *what should this screen look like, what should it say* —
don't need any of that, and blocking on the code thread to answer them wastes both.

So design happens here and lands there. This document is the seam. Everything below
exists to make the handover lossless in one direction and impossible in the other: this
thread **never writes to the repository**. It produces two things — a file and a
statement of intent — and a code session turns them into commits with tests.

## Fill these in

| | |
|---|---|
| `BASE` | The deployed app's URL. Ask the human if you don't have it. |
| `DRIVE_FOLDER` | `1y1HudA1L2Ns36Hx_CmO0BDGDp8bBmfuv` |
| `LINEAR_LABEL` | `design-inbox` |

You need the **Google Drive** and **Linear** connectors. Drive also needs **code
execution and file creation** enabled — without both, saving a file silently isn't an
option and you'll be tempted to paste the mock into an issue instead. Don't.

## Read before you design

The current design is *live*, not remembered. Fetch it:

- `<BASE>/docs` — index of everything, with a line on what each file is for.
- `<BASE>/ux/polyphony-kit.css` — **the single source of truth** for tokens and
  component classes. Every class you use in a mock must already exist here, or your mock
  is proposing a new component and should say so in as many words.
- `<BASE>/ux/polyphony-<screen>.html` — the current mock for the screen you're changing.
- `<BASE>/docs/architecture.md`, `<BASE>/docs/roadmap.md` — what the system does and
  what's planned, when the design question touches either.

Designing from memory is how a mock ends up using a class that was renamed in March. If
a fetch fails, say so and ask — don't reconstruct.

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

Then create a Linear issue with the `design-inbox` label. The issue is the instruction;
the Drive file is the material. Keep them apart — an issue that *contains* the mock is a
second copy of it, and the two will disagree.

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
  `ux/` in the repo, served at `<BASE>/ux/`, and it gets there through a code session.
- **Never edits `docs/`.** Those describe running code, and a doc that's true here and
  false in the repo is worse than one that's missing.
- **Doesn't decide it's done.** The code session ports it, and may come back with a
  reason it can't work as drawn. That's the review, and it's the point of the split.
