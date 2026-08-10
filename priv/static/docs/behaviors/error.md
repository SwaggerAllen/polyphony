# Error

<!-- rev: 1 -->

| | |
|---|---|
| Route | any — rendered instead of a screen |
| Storybook | Screens → Error |
| Code | `PolyphonyWeb.Screens.Error`, `PolyphonyWeb.ErrorHTML` |

The screen you get when there isn't one. It is the only surface in the app that must work
when nothing else does, and the only one nobody chooses to visit.

## Standing decisions

- **It carries no assets.** Everything it needs is inlined — styles, colours, type stack —
  because a broken asset can be the error being shown, and a stylesheet that fails to load
  turns a bad moment into an unreadable one. That constraint decides the implementation, not
  the design: **inlining is not a licence to look like a different product.** The values are
  the kit's own, written out literally rather than referenced, and the fonts degrade to the
  same system stack the kit already falls back to.

  Nothing enforces that today, which is how the current page came to invent its own palette.
  A copy of the kit's values that has to be kept in step by hand will fall out of step, and
  the failure is silent — nobody visits this page on purpose. **Generating the inlined block
  at build time from `polyphony-kit.css` is the fix**, and it is an open investigation rather
  than a requirement; see the issue. Until it exists, a kit change is a reason to look here.
- **A missing page is not an accident.** Most 404s are a mistyped URL or a link that outlived
  what it pointed at, and the person holding it did nothing wrong. The copy says what
  happened, not that something went wrong — the same argument `share.md` makes for
  `dead_link` and `browse.md` for `taken_down`, both of which exist because the generic
  answer was not good enough for a case somebody cared about. This is the answer for every
  case nobody has cared about yet.
- **The page assumes nothing about the session, except where reaching it proves one.** There
  is no *back to your library* for signed-in readers and no pitch for strangers: an error
  screen that has to load a session to render is an error screen that fails when the session
  is what broke. A **403 is the exception, and only because it cannot be reached without
  auth having already run** — deciding something is forbidden means knowing who is asking. So
  that one state may vary by signed-in state, and nothing else may.
- **An opaque resource id is not worth protecting.** A 403 tells you the thing exists, which
  `login.md` refuses to do for email addresses — and that refusal is about **account**
  enumeration, where confirming an address is a fact about a person who never asked to be
  looked up. A campaign id is a random opaque string somebody was given or guessed; knowing
  one exists reveals nothing about anybody and costs a reader the answer they needed. The two
  cases look alike and are not, and collapsing them would make every wrong link a dead end.
- **The request id is always shown.** On a 500 it is the one thing worth quoting; on a 404 it
  is nearly useless. It appears on both anyway, because a support conversation that starts
  *there's no id on my screen* is worse than a line of noise, and because a reader who has
  learned where the id lives should not have to relearn it per status.

## States

### `not_found` — 404

The page isn't there. It says so plainly and does not apologise or imply fault: the two
things a reader wants are confirmation they aren't going mad and a way back.

One route out, to the front door. Not to their library — see the standing decision — and not
a search box, which would promise a lookup this page cannot perform.

### `forbidden` — 403, signed in

*This isn't yours.* The case that actually happens: a collaborator opens a link to a campaign
nobody added them to. Saying *not found* would send them looking for a bug instead of asking
for access.

It offers no request-access control. That is a real feature and this is not the place to
invent it, so the page says who to ask rather than pretending to ask for them.

### `forbidden_signed_out` — 403, signed out

The same fact, and the useful thing to do about it is different. Somebody signed out cannot
tell whether this is a campaign they have access to under an account they aren't currently
in — which is the common case for anybody with more than one device — so the page offers the
sign-in they need rather than an apology they can't act on.

It does **not** say *sign in and you'll have access*, which it cannot know. It says the thing
is real, that access is decided by account, and offers the door.

### `server_error` — 500, with detail

**The ordinary production case**, because `SHOW_ERROR_DETAILS` is on by default and stays
that way — see *Confirmed non-asks*. The exception and stacktrace render below the message in
a monospace block, visually separated so the human sentence stays readable above it.

The message admits fault, which is the difference between this and `not_found`: something did
go wrong, and it was ours. The request id sits with it, which is the moment it earns its
place on every other status.

### `server_error_plain` — 500, with detail switched off

What a reader sees when `SHOW_ERROR_DETAILS` is unset. Same message, same request id, no
block beneath it.

Worth its own state rather than being described as *the same page minus a div*: it is what
anybody would see if the flag were ever turned off, and the page has to stand up without the
detail carrying the weight of the layout.
