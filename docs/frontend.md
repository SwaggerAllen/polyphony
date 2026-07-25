# Frontend (Phoenix LiveView)

The web layer that sits on the event-sourced backend. It is deliberately thin: every
screen is a LiveView over the existing contexts (`Accounts`, `Library`, `Moderation`,
`Notifications`, `Costs`, `DataAccess`) and the per-viewer broadcaster. No business
logic lives in the web layer — it surfaces the domain and enforces nothing the domain
doesn't.

## Running it

```bash
mix deps.get
pg_ctlcluster 16 main start           # Postgres must be up (read models)
MIX_ENV=dev mix ecto.create
MIX_ENV=dev mix ecto.migrate
mix phx.server                        # http://localhost:4000
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
- **No asset build step.** The prebuilt `phoenix.min.js` / `phoenix_live_view.min.js`
  (IIFE globals) are **vendored** under `priv/static/assets/vendor/`, with a hand-written
  `app.js` (LiveSocket + an autoscroll hook) and `app.css` (mobile-first, dark). There is
  no esbuild/tailwind, so it builds with no binary download — offline and in CI.
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

## Sandbox caveat (not an issue in CI / prod)

This development container's OTP install is **stripped of its include headers**. Two
builds need them:

- Phoenix's `phx.gen.cert` mix task extracts records from
  `public_key/include/OTP-PUB-KEY.hrl` (a generated file, absent here). It is stubbed in
  `deps/` locally — the task is a dev cert generator we never call.
- Floki's HTML lexer compiles a leex `.xrl`, which needs
  `parsetools/include/leexinc.hrl`. That header is fetched into the install locally.

A normal OTP install (`erlef/setup-beam` in CI, the release image in prod) ships both
headers, so neither workaround is needed there and neither is committed.

## Deferred views

V2 Scene Index & Branch Navigator, V3 Character Inspector, V7 Location Graph, and the
V10.1 prompt-template editor (`solid`/sandboxed Liquid) are not built yet. The autonomous
Director "Continue" is wired best-effort and wants a hardening pass under real multi-beat
play.
