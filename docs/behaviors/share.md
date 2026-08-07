# Shared link

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/s/:token` |
| Storybook | Screens → Shared link |
| Code | `PolyphonyWeb.Screens.Share`, `PolyphonyWeb.ShareLive` |

What somebody sees when they open an unlisted link to one world or one character. No
account, no session — usually a person who was sent a URL and knows nothing else about
this app.

## Standing decisions

- **A stranger sees the cover, never the thing.** A world's **cover** and a character's
  **premise** are the fields written to be shown: composed from everything underneath them,
  secrets included, under instruction to give none of them away. The bible's rules and the
  sheet's facts — which is where concealment lives — are not on this screen in any state.
- **A dead link is the common case, not an error.** Tokens get revoked, entries get
  unpublished, things get deleted, and the link keeps circulating. The person holding it did
  nothing wrong, so they get a real screen rather than a 404.
- **Nothing here identifies the author's other work.** The link shares one thing; it is not
  a door into a profile.

## States

### `dead_link` — The token no longer resolves

Revoked, unpublished or deleted, and the screen does not distinguish between them — the
distinction is the author's business and none of it changes what the reader can do. It says
what happened in plain words and offers the way to the published shelf.

### `a_world` — A shared world

The name and the cover. Enough for somebody to decide whether they want to see more of it,
and nothing that would spoil it if they do.

### `a_character` — A shared character

Same rule, different field: the premise is what a stranger would be told about this person.

### `untitled` — Shared before it was named

An unnamed draft is a normal thing to have and to send somebody. The fallback reads as a
description of the thing rather than as a missing value.
