# Group editor

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/authoring/group/:id` |
| Storybook | Screens → Group editor |
| Code | `PolyphonyWeb.Screens.GroupEditor`, `PolyphonyWeb.GroupEditorLive` |

A group is written like a character and used as a starting point for others — a crew, a
household, an order. It saves writing the same person five times, and it gives a secret
somewhere to point.

## Standing decisions

- **A group with no secrets grants nothing by belonging to it.** The concealed facts are what
  make this a *membership* rather than a label; a group whose facts are all public is a tag.
- **Nothing propagates silently.** Telling the members a fact fans out into one proposal per
  member, each reviewed on its own in arc review. A group of twelve is twelve decisions,
  because a change made to a template is not automatically a change each of those people
  would have accepted.
- **The tell panel names the fact, not the operation.** *Tell them what?* is the question
  somebody has when they press it, so the panel answers that rather than describing a fan-out.

## States

### `written` — A group with members and a secret

The working state, and the one that shows what a group is for.

### `empty` — A new group, before anything is written

Nothing here should read as broken. An empty group is a normal thing to have for a minute.

### `no_members` — Written, but nobody in it

Its own state because *Tell the members* has nobody to tell, and saying so beats fanning out
to an empty list.

### `generating` — A field being written

Per-field skeleton, so the rest stays editable.

### `telling` — Being asked whether one fact should reach the members

Named by the fact. See the standing decisions.

### `dirty` — Unsaved

The save bar is pinned to the frame, for the same reason as the other two editors: on a
phone, a save control at the bottom of a long form is one nobody finds.
