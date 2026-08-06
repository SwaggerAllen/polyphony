# Polyphony docs

The map of what lives where, and the rule for where new writing goes. Start with
`architecture.md`; reach for the rest when a task points you at it.

## The files

| File | What it holds | The question it answers |
|---|---|---|
| **`architecture.md`** | The as-built design: how the shipped system works and **why it's shaped that way**. | "Why is the code like this?" |
| **`frontend.md`** | The Phoenix/LiveView web layer — how to run it, its testing tiers, its design choices. | "How does the web layer work?" |
| **`deployment.md`** | The OTP release, Dockerfile, and DigitalOcean App Platform path; prod event-store wiring. | "How does it ship to prod?" |
| **`backend-capabilities.md`** | The **catalog** of every backend capability, with a gap register (surfaced / partial / backend-only). A survey of what exists. | "What can the backend already do?" |
| _(the worklist)_ | **Not a document.** Open work lives in **Linear** — team `StrutCo`, project `Polyphony` — one issue per item, carrying the argument that decides it. | "What ships next, in what order?" |
| **`design-thread.md`** | Instructions for the **normal Claude thread** that does design work: what to read, how a mock reaches Drive, how intent reaches Linear. The code thread's half is in `CLAUDE.md`. | "How does design work get handed over?" |
| **`completed-roadmap.md`** | **Shipped work**, moved out of the planning docs so they stay lean. Detail for done backlog/roadmap items lands here. | "What's already been built (and where)?" |
| **`decisions.md`** | Post-v1 **strategy and forward rationale**: monetization, TTRPG resolution, kids/org products, style material, and the ordering logic (P1–P11). | "Why the post-v1 plan is what it is?" |
| **`../CLAUDE.md`** | Operational guide + the non-negotiable invariants. | "How do I work in this repo safely?" |
| **`../ux/`** | The frontend design pass — static mocks (`polyphony-*.html`), the kit, and the UX README. Design output, not docs prose. | "What should the frontend look like?" |

## The boundary that's easy to blur: rationale

Three files and one tracker carry *why*, and they don't overlap:

- **As-built rationale → `architecture.md`.** Why a shipped part is the way it is.
- **Forward rationale → `decisions.md`.** Why an unbuilt, post-v1 feature is planned the way it is.
- **What exists → `backend-capabilities.md`.** A neutral survey, no rationale — just the inventory and its gaps.
- **What to do about the gaps → a Linear issue.** The shaped worklist; each item's *why* travels
  in the issue, in service of a designed screen or a decision.

Scheduling carries no rationale of its own — it *orders* what the docs above justify, which is
why it isn't a file here.

## Where does new content go?

When you're about to write something down, sort it:

1. **Explaining shipped code?** → `architecture.md` (or `frontend.md` / `deployment.md` if it's specifically the web or deploy layer).
2. **A neutral fact about what the backend can do today?** → `backend-capabilities.md`.
3. **A concrete task we've decided we want and know the shape of?** → a **Linear issue** in the
   `Polyphony` project. Not a file. Put the whole argument in the description — an issue that
   only names a task loses the part that decides whether to do it.
4. **The reasoning behind an unbuilt, post-v1 direction?** → `decisions.md`.
5. **Just when/what-order something ships?** → the issue's state and priority in Linear.
6. **A frontend visual/interaction decision?** → `ux/` (a mock or the UX README), not here.
7. **An issue you just finished?** → close it, and if it's worth remembering *how* it was built,
   add it to `completed-roadmap.md`. A closed issue records that it happened; the doc records why
   the code looks like that a year later.
8. **Something we've decided *not* to build?** → the **Confirmed non-asks** document on the
   Linear project. Not an issue — a backlog full of things nobody should build is how a backlog
   stops being read.

If a note is rationale *and* a task, the rationale goes to `architecture.md`/`decisions.md` and
the task goes to Linear, cross-referenced — don't let the two drift into one place.

---

## Reading these outside the repo

They are served by the running app: **`/docs`** is an index of everything here plus
`ux/`, and each file is a plain URL under `/docs/…` or `/ux/…` — markdown as text, the
`ux` mocks as pages. No account, so the URL can be handed to anybody (or to a Claude
thread with no access to a private repo, which is what it was built for).

`mix docs.publish` copies both trees into `priv/static`, because a release ships `priv/`
and nothing else. Run it after editing either; CI and `DocsServedTest` both fail on a
stale copy. Everything published this way is **public on the deployed host** — including
`deployment.md`, which names every environment variable (no values). `Mix.Tasks.Docs.Publish`
is where a file gets left out if that changes.
