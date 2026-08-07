# Resume

<!-- rev: 1 -->

| | |
|---|---|
| Route | `/resume` |
| Storybook | Screens → Resume |
| Code | `PolyphonyWeb.Screens.Resume`, `PolyphonyWeb.ResumeLive` |

Coming back on a device that remembers you. The session has expired but the remember-me
cookie hasn't, so the app knows *which account* wants in and only needs to prove it is still
the same person.

## Standing decisions

- **The address is redacted, always.** The screen knows the address without anybody having
  typed it, which is exactly why it must not print it: a remembered device is one somebody
  else may be holding. `w***@example.com` is enough to recognise your own account and not
  enough to learn somebody else's.
- **It is not a shortcut past sign-in.** Being on a remembered device changes who has to be
  named, not what has to be proved — a link still goes to the address and still has to be
  opened.
- **There is always a way to stop being remembered.** Otherwise a shared laptop keeps
  offering one person's account to everybody who opens it.

## States

### `offer` — Sign back in as you

The account, named by its redacted address, with one button. This is the whole screen on a
good day.

### `sent` — The link is out

Same redaction, and the same escape routes as sign-in — resend, and sign in as somebody
else. Being on a remembered device does not make a mistyped or stale account any easier to
get out of, so nothing is trimmed here on the assumption that the person is known.

### `dev_link` — The link, on the page

`:expose_magic_link` again, dev only and pinned false in production. Worth looking at beside
the other two: on this screen the exposed link is a **full account takeover** for anybody
holding the device, because there is no address to guess.
