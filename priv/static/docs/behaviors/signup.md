# Sign up

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/signup` |
| Storybook | Screens → Sign up |
| Code | `PolyphonyWeb.Screens.Signup`, `PolyphonyWeb.SignupLive` |

Making an account. **Invite-only** while the project is young, so this screen is normally
reached from a code somebody was given rather than from the landing page.

## Standing decisions

- **Consent is a real input.** The attestation and the policy acknowledgements are checkbox
  inputs with labels, reachable and operable by keyboard. A consent you cannot reach with a
  keyboard is not a consent, and this is the one form in the app where that matters legally
  rather than only ethically.
- **Rules are stated before they can be broken.** The username constraint is on the screen
  from the start. A rule you only learn by failing is a rule the form kept to itself.
- **Refusing the attestation ends the signup.** It does not degrade the account or hide
  features — it stops. And it stores nothing: no row, no mail, and the invite stays unspent
  so whoever sent it can pass it on.

## States

### `invited` — The ordinary way in

An invite code, an address, a username, and the consents. Everything a stranger needs to
know about what they are agreeing to is on this screen rather than behind a link they won't
follow.

### `first_account` — The very first account

A fresh install has nobody to have sent an invite, so the first sign-up skips it and becomes
the superadmin. Easy to forget exists, impossible to reach twice, and worth keeping visible
because it is the only path that mints an unassignable role.

### `invite_used` — A spent code

The copy points at **the person who sent it**, not at us. Asking them for another is the
actual next step, and a message about our invite system is not.

### `username_taken` — A field-level error

On the field, not at the top of the form. The answer belongs beside the question.

### `turned_away` — The attestation was refused

A terminal screen. No retry, no go-back, no second chance on the same page — a door that
reopens where you were just refused isn't a door. It says plainly that nothing was stored
and that the invite is still good, because the person reading it is often somebody who
mis-clicked rather than somebody who was excluded.
