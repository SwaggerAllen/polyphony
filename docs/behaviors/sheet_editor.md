# Character sheet

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/authoring/character/:id` |
| Storybook | Screens → Character sheet |
| Code | `PolyphonyWeb.Screens.SheetEditor`, `PolyphonyWeb.SheetEditorLive` |

Writing a person. Everything a character prompt renders comes from this screen, so what is
missing here is what a model will invent.

## Standing decisions

- **Pronouns are a field, not an inference.** Every character prompt renders this sheet, and
  a model guessing from a name lands its wrong guess *inside the fiction*, where it reads as
  the story being wrong about her rather than as a settings mistake.
- **Secrets are written from the secret's side.** The "who else knows" control appears only
  on a concealed fact, and names an audience. Written the other way round — per character,
  what do they know — it would scale with secrets times cast instead of with secrets.
- **An audience is additive only.** A tick inherited from a group cannot be individually
  removed, and the picker says so rather than offering a control that silently does nothing.
- **A relationship targets an id, with a name rendered beside it.** A name is display, and two
  people can share one.
- **The save bar is pinned to the frame, not to the document.** On a phone, a save control at
  the bottom of a long form is a save control nobody finds.

## States

### `written` — A sheet with something on it

The ordinary working state: the five prose fields, the facts, and the panels behind them.

### `blank` — A character who exists and nothing more

A first-run card leads instead of five empty fields. An empty form is a worse question than a
prompt.

### `a_secret` — A concealed fact

The control that only appears on concealment: who else knows.

### `audience_open` — The picker

Groups and people, with somebody already in the audience. Additive only — see the standing
decision.

### `boundaries` — What she won't do

And which way the pressure runs: a **refusal** is a line she holds, a **compulsion** is one
she can't help crossing. Same gate, two directions, and both are enforced in play rather than
suggested to a model.

### `relationships` — Who she's connected to

Both directions of the connection, since what she thinks of him and what he thinks of her are
different facts.

### `generating` — A field being written

The skeleton is per-field, so the rest of the sheet stays editable while one field thinks.

### `dirty` — Unsaved

The save bar, pinned. See the standing decision.

### `in_scenes` — Already played

A scene count, as a quiet warning. Renaming her is safe; what she has already said is in the
event log and isn't editable from here.
