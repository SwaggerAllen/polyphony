# Sign in

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/login` |
| Storybook | Screens → Sign in |
| Code | `PolyphonyWeb.Screens.Login`, `PolyphonyWeb.LoginLive` |

The way in. **Magic link only** — there are no passwords anywhere in the product, so this
screen and the mail it sends are the entire authentication surface.

## Standing decisions

- **Email is the front door, and it fails quietly.** An unconfigured mailer means nobody
  can sign in, and the default transport records the notification as sent. Anything that
  changes how the link is delivered has to consider that failure mode explicitly.
- **The screen must never reveal whether an address has an account.** Every path through it
  ends on the same page with the same words. This is the one rule here that is not a
  preference: a login screen that answers *does this person exist* is an enumeration oracle,
  and the trade against it is a moment's ambiguity for somebody who mistyped.
- **Two fields, not one that takes either.** Keeping the address as `type="email"` lets the
  browser catch a typo'd domain before it becomes a silent no-match — which, under the rule
  above, is indistinguishable from having no account.

## States

### `signed_out` — Asking for a link

The default. An address, a submit, and nothing else to get wrong.

### `sent` — The link is out

This state *is* the experience of a passwordless sign-in, so it carries both escape routes —
resend, and change the address — plus the line about checking spam, **before** anybody has
had to go looking for them. A screen that waits to be asked has already lost the person
staring at an empty inbox.

### `sent_to_nobody` — An address with no account

Byte-identical to `sent`, deliberately. Nothing about this state should ever be made to
differ from the one above; if a change would make them distinguishable — different copy,
different timing, a different resend behaviour — that change is the bug.

### `dev_link_exposed` — The link, on the page

`:expose_magic_link`. Dev only, and pinned false in production by a test, because it hands a
working session to anyone who can type a known address. It has a state here so the control
is something you can look at deliberately rather than something you discover by accident.

### `signed_in` — Already have a session

Reached by somebody who is signed in and landed here anyway. The corner menu is the only
difference and it is the point: the useful thing to offer is a route onward, not a second
sign-in.
