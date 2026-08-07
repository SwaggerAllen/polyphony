# Arc review

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/arc/:campaign_id` |
| Storybook | Screens → Arc review |
| Code | `PolyphonyWeb.Screens.ArcReview`, `PolyphonyWeb.ArcReviewLive` |

What play decided about your people and your world, **proposed rather than applied**. A
scene can conclude that Wren no longer trusts the harbour office; this is where you decide
whether that is now true of her.

## Standing decisions

- **Nothing a scene decides is applied on its own.** Accepting is a deliberate act, and
  refusing one is not a rejection of the scene — it is how you write the person who didn't
  go along with what happened to them. That asymmetry is the whole feature.
- **Every proposal carries a Because line and its provenance.** Which scene, which beat.
  Without it a proposal is an assertion about somebody you wrote, from nowhere.
- **The gate is per-cast, not per-backlog.** Nineteen proposals pending on a different
  campaign do not block opening a scene with two — otherwise the review queue becomes a
  reason not to play.
- **A group change is one card, not one per member.** It is really one proposal against the
  template plus one per current member; a group of twelve would otherwise flood the queue
  from a change nobody made twelve times.

## States

### `proposals` — What a scene decided about somebody

The working state: cards, each with its Because line, accept and reject.

### `nothing_pending` — A character the scene had nothing to say about

Normal, and frequent. See the per-cast standing decision.

### `editing` — Correcting a proposal before taking it

Rather than accepting or rejecting it whole. This is the precedent the authoring review
panel is meant to copy.

### `world_arc` — The world tab

A **global** fact reaches everywhere; a **local** one reaches only its scene's location.
Which is why the scope is a control here rather than an assumption baked into the proposal.

### `group_fan_out` — A group change, collapsed

One card standing for the template change and one proposal per current member.
