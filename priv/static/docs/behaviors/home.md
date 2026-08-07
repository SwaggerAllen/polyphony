# Home

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/` |
| Storybook | Screens → Landing |
| Code | `PolyphonyWeb.Screens.Home`, `PolyphonyWeb.HomeLive` |

The only screen in the app whose job is to **explain what this is**. Everybody else has
already decided to be here; this one is talking to somebody who hasn't.

## Standing decisions

- **Below the fold is argument, not product.** Somebody arriving has no reason to care
  yet, so the page spends its length making the case rather than demonstrating features
  they have no context for.
- **It does not change shape when you sign in.** A returning visitor gets the same page
  plus a route to their own work. Rebuilding the landing page into a dashboard would mean
  maintaining two screens to serve one URL, and the dashboard already exists — it is the
  library.

## States

### `signed_out` — The pitch

What Polyphony is, for somebody who has never heard of it. The one thing this screen has to
land is that a scene is played by several people at once and each of them knows something
different — everything else follows from that and nothing else distinguishes it.

### `signed_in` — The same page, with a way out

Identical, except the corner menu now routes to the library, browse and settings. That
difference is the whole reason this screen takes a current user at all: somebody who
already has work here needs a door to it, not the pitch they have already read.
