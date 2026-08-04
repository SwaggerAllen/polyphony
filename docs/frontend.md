# Frontend (Phoenix LiveView)

The web layer that sits on the event-sourced backend. It is deliberately thin: every
screen is a LiveView over the existing contexts (`Accounts`, `Library`, `Moderation`,
`Notifications`, `Costs`, `DataAccess`) and the per-viewer broadcaster. No business
logic lives in the web layer — it surfaces the domain and enforces nothing the domain
doesn't.

## Running it

```bash
mix deps.get
mix assets.setup                      # fetch esbuild + tailwind binaries (once)
pg_ctlcluster 16 main start           # Postgres must be up (read models)
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ecto.migrate
mix phx.server                        # http://localhost:4000 (watches + rebuilds assets)
```

Dev runs fully offline: the LLM is `Polyphony.LLM.Mock` (deterministic lorem), and email
is the logging notifier. The **magic-link** sign-in surfaces its link directly on the
login page in dev (no mailer needed) — the first account to sign up becomes the
superadmin.

## The design kit

The redesign speced in `ux/` is being ported screen by screen. Two files carry it:

- **`assets/css/kit.css`** — generated, and a *verbatim* copy of
  `ux/polyphony-kit.css` but for the kit's §11 mock chrome. `mix kit.port` derives it and
  `PolyphonyWeb.KitPortTest` fails the build if the two disagree, so the design file really
  is the single source of truth. To change the look: edit `ux/polyphony-kit.css`, run
  `mix kit.port`, run `mix assets.build`, commit all three. Never edit the generated file.
- **`lib/polyphony_web/components/kit.ex`** — the kit's markup as function components. A
  ported screen calls these; it doesn't re-derive class strings, and it defines nothing
  screen-local the kit already provides.

`app.css` is an ordered manifest — Tailwind, then the kit — and the order is load-bearing:
the kit is last so it outranks a utility it overlaps with, which is the precedence the mocks
have (they link the kit after the Tailwind CDN).

**The first-cut design system is gone**, and with it any styling for the screens that
haven't been ported: they render as unstyled markup until each is rebuilt from the kit. That
is deliberate rather than an oversight — the app has no users until the rebuild lands, so
there's no reason to carry 400 lines of superseded CSS, and no reason for the shipped
stylesheet to be anything other than the design file. The screens themselves and their
tests **are** kept, as the record of how each one drives the domain; each goes when its
replacement lands.

**The shell is thin, by design.** There is no persistent global chrome: a screen fills the
viewport and carries its own header (`Kit.header/1` — context small, title, controls top
right, overflow last), and going elsewhere is that header's back chevron or its overflow
menu (`Kit.menu/1`, filled by `Layouts.nav_menu/1`). A standing nav bar would cost a row of
vertical space on every screen of a product whose main surface is a transcript. `<body>`
carries the register (`fr stage dark`), which is what gives the document a backdrop and
makes the kit's tokens resolve outside a screen's own frame; a screen nests its own frame
when it needs a different register, as play does for a character viewer.

Browse the components at **`/storybook`** (`mix phx.server`, then
<http://localhost:4000/storybook>) — one page per component with its states. It's on in dev
and test, and elsewhere only with `STORYBOOK=true`. `PolyphonyWeb.StorybookTest` renders
every story and asserts every kit component has one, so the catalogue can't drift from the
components.

## Design choices worth knowing

- **Modern toolchain.** Phoenix 1.8 / LiveView 1.2 on OTP 27 / Elixir 1.17 (installed by
  the SessionStart hook, or the base image once it's updated). The server is **Cowboy**,
  not Bandit — Phoenix 1.8 defaults to Bandit but Cowboy is fully supported and already
  wired here. LiveView 1.2's test DOM backend is `lazy_html` (a precompiled NIF), not
  Floki, so that's the only test-only web dep.
- **Real asset pipeline, committed outputs.** Source lives in `assets/` — `js/app.js`
  (LiveSocket + an autoscroll hook, importing `phoenix`/`phoenix_live_view` from `deps/`)
  and `css/app.css` (a manifest: Tailwind, then the ported design kit).
  esbuild bundles the JS and Tailwind builds the CSS via standalone binaries (no Node.js),
  fetched by `mix assets.setup`. The **built outputs** (`priv/static/assets/app.{js,css}`)
  are committed, so the app still compiles and serves with no build step — offline and in
  CI. Rebuild after touching `assets/` with `mix assets.build` (or run `mix phx.server`,
  which watches). `mix assets.deploy` is the minified + digested prod build.
- **Auth is transport only** (`PolyphonyWeb.Auth`). The domain (`Accounts`) already
  decides who may do what; the web layer signs a `Phoenix.Token`, verifies it, and stores
  the user id in the session. `on_mount` hooks (`require_authed` / `require_admin`) gate
  the live sessions.
- **Remember-me is a hint, never a credential.** The session cookie has no `max_age`,
  so it dies with the browser — which on a phone is whenever the OS decides. Signing in
  therefore also sets `_polyphony_remember`: encrypted, http-only, 60 days, holding a
  user id and nothing else. An expired session on a remembered device lands on
  `/resume` — one button that emails a fresh magic link — rather than a form asking for
  an address the server already knows. It buys **only** that button: the link still goes
  to the inbox, which is the one thing a stolen phone doesn't come with, and that is
  what lets it outlive the session by two months. `/auth/forget` deletes it (a GET,
  because nothing over the socket can set a cookie), and so does signing out — expiring
  and leaving are different things.
- **Ownership through `Owner`.** Library screens scope every read/write through
  `Polyphony.Owner.of(current_user)` — never a raw user id — so org support later is a
  bolt-on, not a rewrite (decisions §P2/§P8).
- **The Play view is the guarantee, visible.** It renders a scene as a
  viewer-parameterized projection (omniscient or as any character); a whisper the viewer
  wasn't part of is silently absent. That is `Polyphony.Visibility.project/2` — the same
  filter play runs on — and a LiveView test pins it end-to-end.

## Toolchain note

The frontend runs on **Elixir 1.17 / OTP 27**, installed by the `SessionStart` hook
in Claude Code on the web (or by an updated base image). OTP 27 ships its include
headers, so the old workarounds this section used to describe — a stubbed
`phx.gen.cert` and a hand-fetched `leexinc.hrl` for Floki's lexer — are gone. The
test DOM backend is now `lazy_html` (LiveView 1.2's default), which has no leex
dependency at all.

## Testing tiers

Three layers, cheapest first:

1. **`Phoenix.LiveViewTest`** (`test/polyphony_web/live/`) — in-process, no browser:
   router → auth → mount → contexts → domain → rendered HTML. The whisper-visibility
   guarantee is pinned here. Runs in the default `mix test`.
2. **Persistent event-store E2E** (`test/polyphony/persistent_event_store_test.exs`) —
   dispatches through the *production* EventStore adapter against Postgres and reads
   the stream back, so prod event-store wiring is covered in CI. Tagged
   `:event_store`, runs in the default suite (`async: false`).
3. **Real-browser feature test** (`test/polyphony_web/features/`, Wallaby) — drives
   Chromium over a live LiveSocket WebSocket, exercising the actual JS bundle and the
   guarantee through two viewers. Tagged `:feature` and **excluded from the default
   run** (the fast suite and the CI unit job need no browser). Run locally with:

   ```bash
   bin/setup-chromedriver        # installs a chromedriver matching the local Chromium
   mix test --only feature
   ```

   `config/test.exs` auto-detects the Chromium binary and driver (override with
   `WALLABY_CHROME_BINARY` / `WALLABY_CHROMEDRIVER`). The endpoint serves in test and
   the `Phoenix.Ecto.SQL.Sandbox` plug lets the browser share the test's DB
   connection.

## Deferred views

V2 Scene Index & Branch Navigator, V3 Character Inspector, V7 Location Graph, and the
V10.1 prompt-template editor (`solid`/sandboxed Liquid) are not built yet. The autonomous
Director "Continue" is wired best-effort and wants a hardening pass under real multi-beat
play.
