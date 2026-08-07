# World bible

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/authoring/bible/:id` |
| Storybook | Screens → World bible |
| Code | `PolyphonyWeb.Screens.BibleEditor`, `PolyphonyWeb.BibleEditorLive` |

Writing a world: what it is, how it sounds, what is true in it, and which of those truths
are known to whom.

## Standing decisions

- **Rules and starting canon are the same kind of thing.** Both are entry lists carrying the
  same concealment control, and that sameness is the point — to a reader they *are* the same
  thing: something true that may or may not be known. Giving them different controls would be
  inventing a distinction the fiction doesn't have.
- **The cover is the only field a stranger sees.** It is written from everything below it,
  secrets included, under instruction to give none of them away. That is what makes it safe
  on a shared link, and it is why it can't simply be the setting field.
- **The preview goes through the same call the prompt does.** What an author previews cannot
  drift from what a character's conditioning actually contains — if the two ever diverge, the
  preview is a lie about the guarantee this product is built on. It says *how much* is held
  back without saying what.
- **A resolved audience answers "right now".** Somebody joining a group changes what a
  secret's audience line says, without anybody touching the secret.
- **A name clash is flagged on save, not on every keystroke.** A name you are halfway through
  typing always clashes with nothing.

## States

### `written` — A world with something in it

Cover, setting, tone, rules, starting canon.

### `blank` — A world that exists and nothing more

The cover placeholder does the explaining, since it is the only part a stranger ever sees.

### `a_secret` — A concealed rule

With the line saying how many others know it.

### `audience_open` — The picker, with a group ticked

See the standing decision about resolution.

### `preview` — What a character's prompt gets

Read-only, filtered through the same call the context path uses.

### `cover_written` — The cover

The one field written to be shown.

### `generating` — A field being written

Per-field skeleton, so the rest stays editable.

### `name_clash` — Two worlds with the same name

Flagged on save. Not an error — you are allowed two — but not something to discover later
either.

### `copied` — This world belongs to a campaign

A world attached to a campaign is a **copy**. The original stays on the shelf; the line says
where this one came from, so nobody edits it expecting the other to change.

### `dirty` — Unsaved

The save bar carries the name clash, which is the one thing only Save can tell you.
