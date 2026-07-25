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

## Design choices worth knowing

- **Modern toolchain.** Phoenix 1.8 / LiveView 1.2 on OTP 27 / Elixir 1.17 (installed by
  the SessionStart hook, or the base image once it's updated). The server is **Cowboy**,
  not Bandit — Phoenix 1.8 defaults to Bandit but Cowboy is fully supported and already
  wired here. LiveView 1.2's test DOM backend is `lazy_html` (a precompiled NIF), not
  Floki, so that's the only test-only web dep.
- **Real asset pipeline, committed outputs.** Source lives in `assets/` — `js/app.js`
  (LiveSocket + an autoscroll hook, importing `phoenix`/`phoenix_live_view` from `deps/`)
  and `css/app.css` (Tailwind base/utilities + the mobile-first dark design system).
  esbuild bundles the JS and Tailwind builds the CSS via standalone binaries (no Node.js),
  fetched by `mix assets.setup`. The **built outputs** (`priv/static/assets/app.{js,css}`)
  are committed, so the app still compiles and serves with no build step — offline and in
  CI. Rebuild after touching `assets/` with `mix assets.build` (or run `mix phx.server`,
  which watches). `mix assets.deploy` is the minified + digested prod build.
- **Auth is transport only** (`PolyphonyWeb.Auth`). The domain (`Accounts`) already
  decides who may do what; the web layer signs a `Phoenix.Token`, verifies it, and stores
  the user id in the session. `on_mount` hooks (`require_authed` / `require_admin`) gate
  the live sessions.
- **Ownership through `Owner`.** Library screens scope every read/write through
  `Polyphony.Owner.of(current_user)` — never a raw user id — so org support later is a
  bolt-on, not a rewrite (roadmap §P2/§P8).
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
