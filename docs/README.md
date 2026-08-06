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
| **`backend-backlog.md`** | The standing **engineering worklist**: shaped backend work not built yet, and the immediate milestone that gates the current design. | "What backend work is queued, and what's its shape?" |
| **`roadmap.md`** | The near-term **schedule**: what's *left* — the open §A/§B items, the frontend rebuild, and the order. Shipped work is not here. | "What ships next, in what order?" |
| **`completed-roadmap.md`** | **Shipped work**, moved out of the planning docs so they stay lean. Detail for done backlog/roadmap items lands here. | "What's already been built (and where)?" |
| **`decisions.md`** | Post-v1 **strategy and forward rationale**: monetization, TTRPG resolution, kids/org products, style material, and the ordering logic (P1–P11). | "Why the post-v1 plan is what it is?" |
| **`../CLAUDE.md`** | Operational guide + the non-negotiable invariants. | "How do I work in this repo safely?" |
| **`../ux/`** | The frontend design pass — static mocks (`polyphony-*.html`), the kit, and the UX README. Design output, not docs prose. | "What should the frontend look like?" |

## The boundary that's easy to blur: rationale

Four files carry *why*, and they don't overlap:

- **As-built rationale → `architecture.md`.** Why a shipped part is the way it is.
- **Forward rationale → `decisions.md`.** Why an unbuilt, post-v1 feature is planned the way it is.
- **What exists → `backend-capabilities.md`.** A neutral survey, no rationale — just the inventory and its gaps.
- **What to do about the gaps → `backend-backlog.md`.** The shaped worklist; each item's *why* is local to the item, in service of a designed screen or a decision.

`roadmap.md` carries no rationale of its own — it *schedules* what the other four justify.

## Where does new content go?

When you're about to write something down, sort it:

1. **Explaining shipped code?** → `architecture.md` (or `frontend.md` / `deployment.md` if it's specifically the web or deploy layer).
2. **A neutral fact about what the backend can do today?** → `backend-capabilities.md`.
3. **A concrete backend task we've decided we want and know the shape of?** → `backend-backlog.md`.
4. **The reasoning behind an unbuilt, post-v1 direction?** → `decisions.md`.
5. **Just when/what-order something ships?** → `roadmap.md`.
6. **A frontend visual/interaction decision?** → `ux/` (a mock or the UX README), not here.
7. **A backlog/roadmap item you just finished?** → move its detail to `completed-roadmap.md` and
   leave a one-line pointer in the source file, so the planning docs don't accrete done items.

If a note is rationale *and* a task, the rationale goes to `architecture.md`/`decisions.md` and the
task goes to `backend-backlog.md`, cross-referenced — don't let the two drift into one file.
