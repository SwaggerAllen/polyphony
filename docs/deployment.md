# Deployment — DigitalOcean App Platform + DeepInfra

How to run Polyphony in production on DigitalOcean App Platform. The app ships as a
self-contained OTP release built by the repo `Dockerfile`; CI/CD lives in
`.github/workflows/`.

> **Status.** Deployable. `ci.yml` runs on every push (format, `--warnings-as-error`
> compile, asset-drift check, full suite). `.do/app.yaml` describes the app and
> `deploy.yml` syncs it via `doctl` on a tag or manual dispatch. The release, the
> Dockerfile, and the persistent event store are all in place and verified.

## The shape of it

- **One OTP release.** `mix release` produces `bin/polyphony`; the Dockerfile builds
  it and copies just the release onto a slim Debian runner (no Elixir/Mix). Overlay
  scripts `bin/server` (boot) and `bin/migrate` (deploy migrations) wrap it.
- **One managed Postgres 16 cluster, two schemas.** The read models live in `public`;
  the persistent event store lives in a dedicated `eventstore` schema. Both come from
  the single `DATABASE_URL` App Platform injects.
- **The web service migrates itself on boot** (`Polyphony.Release.migrate/0`, gated
  by `MIGRATE_ON_BOOT`) before it serves — the single migrator, so nothing contends
  on the migration lock.

## Prerequisites

- A DigitalOcean account and [`doctl`](https://docs.digitalocean.com/reference/doctl/).
- A DeepInfra API key.
- Repo secrets for CD: `DIGITALOCEAN_ACCESS_TOKEN` (App Platform write), `DO_APP_ID`.

## DeepInfra integration

Generation goes through the provider boundary (`Polyphony.LLM.Provider`); the live
adapter is `Polyphony.LLM.DeepInfra` (Erlang `:httpc`). In prod the whole `:llm`
config is env-driven (`config/runtime.exs`), so you configure it from App Platform
without a code change:

- **`DEEPINFRA_API_KEY`** — secret; the adapter sends it as the bearer token.
- **`DEEPINFRA_MODEL`** — the **workhorse** model, used on every turn. This is the
  deployment-wide default; a campaign can override it (see below).
- **`DEEPINFRA_MODEL_HEAVY`** — reserved for character/world generation and the
  refusal/empty model-swap (falls back to the workhorse if unset).

> **Per-campaign override.** These two env vars set the *global* default. A campaign
> can point its Director + cast at a different model — and its own heavy fallback —
> from **Model tuning** on the campaign screen (`:llm` on the campaign payload;
> `Polyphony.LLM.Settings`). Leave a field blank to inherit the env default. This is
> the escape hatch when a model's serverless pool is overloaded (a 429 with
> `engine_overloaded`): move that campaign to a better-provisioned model without a
> redeploy. Takes effect on the next beat.
>
> **Service tier.** The same screen picks DeepInfra's per-request scheduling tier —
> `priority` (schedules ahead of standard traffic; the direct fix for
> `engine_overloaded` under peak load, ~1.5× price), `flex` (cheaper, best-effort),
> or `standard` (the default; sent as no tier). Set on the campaign's `:llm` payload
> and applied to every generation it makes. Availability varies by model.
- `DEEPINFRA_EMBED_MODEL` — optional; the embedding model for pgvector memory
  (defaults to `BAAI/bge-large-en-v1.5`). ⚠ **Must be 1024-dim** to match the
  `character_scene_summaries.embedding` column — a different-dimension model needs
  a migration. Prod embeds real vectors here; dev/test use the offline mock.
- `DEEPINFRA_BASE_URL` — optional; defaults to `https://api.deepinfra.com`.

> ⚠ **The model ids in `config/config.exs` are placeholders** (illustrative Qwen
> strings), so a deploy that doesn't set `DEEPINFRA_MODEL` will 404 on the first
> generation. Look up the exact model ids in your DeepInfra dashboard and set the
> two env vars before the first run. Everything else stays offline — nothing but
> the DeepInfra call leaves the box.

## Email, and how anyone signs in

Sign-in is **magic-link only — there are no passwords**. That makes the mailer part of
the critical path rather than a nicety: with no mail configured, nobody can get in.

The trap to know about is that this fails *quietly*. `Notifications` talks to a
pluggable transport, and the default is `Transport.Log`, which writes
`email → someone@example.com: <subject>` to the log and returns `{:ok, :logged}`.
Every layer above it then behaves as though delivery succeeded — the `notifications`
row is written with status `"sent"`. A log full of successful sends and an empty inbox
is the symptom.

`runtime.exs` swaps in the real transport **only when `SMTP_HOST` and `MAIL_FROM` are
both set**. Half-configured stays on the logging transport deliberately, so the
failure is "no mail configured" rather than a stream of relay errors.

- `SMTP_HOST` — the relay **hostname, with no port on it**. `SMTP_PORT` carries the
  port. A host of `smtp.example.com:587` is handed straight to DNS by gen_smtp and
  fails as `:nxdomain` — an error that names DNS rather than the mistake — so a port
  found on the host is now split off and used, but keeping them separate is clearer.
- `SMTP_PORT` — defaults to `587` (STARTTLS), which every provider offers. `465`
  switches to implicit TLS on its own; you do not need `SMTP_SSL`. **Avoid `25`**: it
  is server-to-server relay and App Platform, like most hosts, blocks it outbound —
  which surfaces as a network timeout rather than anything mentioning ports.
- `SMTP_SSL` — override the port's TLS shape. Rarely wanted, and the two are not
  additive: implicit TLS is the whole connection, STARTTLS is an upgrade partway
  through a plaintext one, so exactly one of them applies. A mismatch is warned about
  at boot because it fails as a dropped connection with nothing about TLS in it —
  plaintext at 465 gets hung up on (`{:network_failure, …, {:error, :closed}}`), and a
  handshake at 587 is answered with a plaintext banner the client can't read.
- `SMTP_USERNAME` / `SMTP_PASSWORD` — provider credentials. **Postmark uses the
  Server API token as both**, which is easy to miss when you are looking for a
  username; there is no separate SMTP user.

The boot log prints what was resolved — `[boot] mail relay=host:port tls=starttls
from=… auth=set` — so a misconfiguration is visible on startup rather than at the
first failed send. `auth=MISSING` means `SMTP_USERNAME` never arrived.

### Reading a send failure

The four failure shapes name four different mistakes, and only one of them is about
the network:

| Error | What it means |
|---|---|
| `{:network_failure, host, {:error, :nxdomain}}` | The relay name doesn't resolve. Usually a port left on `SMTP_HOST`, or a typo'd domain. |
| `{:temporary_failure, host, :tls_failed}` + `hostname_check_failed` | Connected, but the certificate is for a different name — read the `{:received, …}` list, it names the host you should have used. |
| `{:network_failure, host, {:error, :closed}}` | Connected, then the relay hung up without a reply. Either the TLS shape is wrong for the port (see `SMTP_SSL` above), or the provider is refusing the account — a new or under-review account is the common one. |
| `{:permanent_failure, host, :auth_failed}` | Reached AUTH and was rejected: wrong credentials. Check the username column in the table below before assuming the key is bad. |

Every one arrives wrapped in `{:retries_exceeded, …}`, which just means all three
attempts failed the same way.

When the word alone isn't enough — `:closed` in particular, which means something
different before the banner than after AUTH — set **`SMTP_TRACE=true`** and send
again. gen_smtp then logs the conversation line by line (`[mail] smtp: connected to …
banner was 220 …`), so you can see how far it got. It goes through the debug drawer
like everything else, which is how you read it from a phone. Credentials are redacted
— gen_smtp traces its entire options proplist on one branch, password included — but
it is still a per-send log of a network conversation, so turn it off afterwards.

### Locally

Dev needs no provider: it runs Swoosh's `Local` adapter behind the same
`Transport.Email`, and `/dev/mailbox` renders what was sent. That is the only way to
see the real message — the body, and the provider headers — since the login screen's
on-page link bypasses mail entirely. Both the adapter and the route are dev-only, and
the route is compiled in only when `:dev_mailbox` is set, because it displays every
magic link the app has issued.

### Running without a provider

For a deployment that is still just you, mail can be captured in memory instead of
sent. Set `MAILBOX_PASSWORD` (and optionally `MAILBOX_USER`, default `polyphony`) and
leave `SMTP_HOST` unset: the Local adapter takes the mail and `/dev/mailbox` renders
it, behind HTTP Basic auth.

Basic auth rather than the admin role, deliberately — the moment you need to read a
sign-in link is the moment you are *not* signed in, so an admin gate would lock the
door with the key inside. Unset, the route returns 404 rather than 401, so an unarmed
deployment doesn't advertise that the viewer exists. A configured `SMTP_HOST` always
wins, so a leftover `MAILBOX_PASSWORD` can't quietly divert real mail into a buffer.

> ⚠ **Anyone with these credentials can read every magic link this node has sent** —
> which is every account. It is a single-operator bring-up affordance, not a feature.
> Two other things to know: the store is unbounded and in memory, so it grows until
> restart and is empty after one; and it is per-node, so with more than one instance
> you see whichever answered. Move to a provider before anyone else has an account.

### When the log says `sent` and nothing arrives

A `sent` line means the relay returned a 250 and took the message. It is *theirs*
now, and nothing after that point is visible to this app — so the send line carries
the relay's own reply, which for Postmark includes the MessageID to search their
Activity feed by. Start there; it will say what happened next. Common answers:

- **The token is a Test token.** Postmark servers issue separate Live and Test
  credentials, and the Test one accepts everything and delivers nothing. This is the
  single easiest way to get a clean 250 and an empty inbox.
- **The account is pending approval.** New Postmark accounts can only send to your
  own confirmed address until they approve it.
- **`MAIL_FROM` isn't a confirmed Sender Signature.** Usually rejected at send time,
  but worth confirming it matches exactly.

None of these can be diagnosed from this side, which is the point of logging the
MessageID: it is the handle that makes the provider's side searchable.
- `MAIL_FROM` — the sender address. **It must be on a domain you have verified with
  the provider**; an unverified sender is the most common reason mail vanishes without
  an error.
- `MAIL_FROM_NAME` — display name, defaults to `Polyphony`.
- `POSTMARK_MESSAGE_STREAM` — the stream to send on. Postmark routes by stream and
  the `X-PM-Message-Stream` header names it; a message without one goes to the
  server's default, which may not be the stream you are watching. Defaulted to
  `outbound` when the relay is a `postmarkapp.com` host, so it needs setting only for
  a non-default stream. Not sent to other providers — it is a vendor header.

SMTP rather than a provider HTTP API is a deliberate choice: Resend, Postmark,
SendGrid, Mailgun and SES all speak it, so the provider is a credential rather than a
deploy. Switching is `SMTP_HOST` + credentials and nothing else — the only
provider-specific behaviour in the app is the Postmark message-stream header, and it
is conditional on a `postmarkapp.com` relay, so it stays out of the way.

The one thing that catches people is the **username**, which is rarely a username:

| Provider | `SMTP_HOST` | `SMTP_USERNAME` | `SMTP_PASSWORD` |
|---|---|---|---|
| Postmark | `smtp.postmarkapp.com` | Server API token | the same token |
| Resend | `smtp.resend.com` | literally `resend` | API key |
| SendGrid | `smtp.sendgrid.net` | literally `apikey` | API key |
| Mailgun | `smtp.mailgun.org` | the SMTP login (`postmaster@…`) | its SMTP password |
| Amazon SES | `email-smtp.<region>.amazonaws.com` | SES **SMTP** credentials | ditto |

All of them use port 587 with STARTTLS, which is the default here. SES's SMTP
credentials are derived from an IAM user and are *not* the IAM access key — generating
them is a separate step.

Worth knowing before you pick: transactional providers approve accounts by hand and
several decline anything adult-adjacent, regardless of the mail itself being nothing
but sign-in links. If that becomes a pattern, SES on a domain you own asks the fewest
questions, at the cost of setting up DKIM yourself. The TLS options in `runtime.exs` verify the relay's certificate against the
system CA bundle — `gen_smtp` defaults to `:verify_none`, which would hand the
credentials to anyone who can answer for the host.

Verification also needs `customize_hostname_check` with the `:https` match fun, and
this is not optional in practice: Erlang's default check is strict RFC 6125 and will
**not** match `*.postmarkapp.com` against `smtp.postmarkapp.com`. Providers almost
always serve a wildcard, so without it every send dies at the handshake with
`:tls_failed` and a `hostname_check_failed` alert — which reads like a bad
certificate rather than a missing option.

> If outbound SMTP turns out to be blocked, swapping to a provider's HTTP API is a
> config line plus that adapter's HTTP client dep — `Polyphony.Mailer` and the
> `Transport` seam don't change.

### Getting in the first time

The **first account created in the database becomes superadmin** and needs no invite
(`Accounts.gate_signup/2`); every later signup needs a valid unspent invite. So the
bootstrap is: deploy with mail working, sign up once, and that account is the admin.

If you need a link before mail works, mint one from the running release — this is the
supported way in, and it needs shell access to the box, which is the point:

```bash
bin/polyphony rpc 'Polyphony.Accounts.get_by_email("you@example.com") |> PolyphonyWeb.Auth.deliver_magic_link() |> IO.puts()'
```

That prints the URL (15-minute TTL) and sends it via whatever transport is configured.

> The sign-in screen can also print the link on the page, but **only outside prod** —
> `:expose_magic_link` in `config/config.exs`, false for `MIX_ENV=prod` and pinned by a
> test. It must never be on in production: it hands a working session to anyone who
> types a known address.

## First deploy

1. **Create the app from the spec:**

   ```bash
   doctl apps create --spec .do/app.yaml
   ```

   This provisions the `web` service and the managed `db` (Postgres 16). Note the
   returned app id and set it as the `DO_APP_ID` repo secret for CD.

2. **Set secrets / env.** `.do/app.yaml` declares them; fill in the `SECRET` ones in
   the App Platform UI (or via `doctl`):

   | Var | Source |
   |-----|--------|
   | `SECRET_KEY_BASE` | `mix phx.gen.secret` (64 bytes) |
   | `DEEPINFRA_API_KEY` | your DeepInfra key |
   | `SMTP_HOST` / `SMTP_USERNAME` / `SMTP_PASSWORD` | your mail provider's SMTP credentials |
   | `MAIL_FROM` | sender address, on a domain verified with that provider |
   | `DEEPINFRA_MODEL` | real workhorse model id (replace the spec placeholder) |
   | `DEEPINFRA_MODEL_HEAVY` | real heavy model id (replace the spec placeholder) |
   | `DATABASE_URL` | injected from the managed db (`${db.DATABASE_URL}`) |
   | `PHX_HOST` | injected app domain (`${APP_DOMAIN}`) |
   | `POOL_SIZE` / `EVENT_STORE_POOL_SIZE` | DB connection pools (spec: 5 / 2 — see budget below) |
   | `SHOW_ERROR_DETAILS` | `true` shows the full exception + stacktrace on 5xx pages (bring-up); set `false` before going public |

3. **pgvector.** DO's managed Postgres 16 ships `pgvector`, and the read-model
   migration runs `CREATE EXTENSION IF NOT EXISTS vector;`, so the release-time
   migrate is enough. (If your cluster's role can't create extensions, enable it once
   from the DO console first.)
4. **Database SSL** (handled automatically). DO's managed Postgres requires SSL and
   hands you a `DATABASE_URL` ending in `?sslmode=require`. `config/runtime.exs`
   strips that query param (Postgrex ignores it and the eventstore parser rejects it)
   and enables SSL on both the Repo and the event store with `verify: :verify_none`
   (encrypted, cert not pinned). To verify DO's cert, download its CA and set
   `DATABASE_SSL_CACERTFILE` to the path; set `DATABASE_SSL=false` only for a
   non-SSL/local database.

## Migrations & the event store on deploy

On boot the web service runs `Polyphony.Release.migrate/0` (before it serves):

1. runs pending read-model Ecto migrations (`public` schema), then
2. creates the `eventstore` schema if absent (over the existing `DATABASE_URL`
   connection — no `CREATE DATABASE`), and initializes/upgrades the event store
   tables.

**Event-store schema privilege (one-time).** `CREATE SCHEMA` needs `CREATE` on the
database. On DO's managed DB the app user can create tables in `public` (so the read
models migrate fine) but often **lacks database-level CREATE**, so the event-store
step fails with `permission denied for database …`. Two ways to fix it once:

- **No DB console? Use `DB_ADMIN_URL` (easiest).** Set the `DB_ADMIN_URL` env var to
  your admin connection string (DO's `doadmin`, from the cluster's Connection
  Details) and redeploy. On boot the app connects with those admin credentials **to
  your app's database** and creates the schema **owned by the app user** (so no
  further grants are needed), then proceeds as the app user. Note: the database in
  the `doadmin` string is `defaultdb` and is ignored — the schema is created in the
  database from `DATABASE_URL` (override with `DB_ADMIN_DATABASE` if needed). Once
  it's created, **remove `DB_ADMIN_URL`** — it's only needed the once; `migrate/0`
  detects the existing schema and skips the privileged create on later boots.

- **Have a DB console?** As the admin, run once then redeploy:

  ```sql
  CREATE SCHEMA IF NOT EXISTS eventstore AUTHORIZATION "<app_user>";
  ```

  (Owning the schema gives the app user create/use on it without database-level
  CREATE. `GRANT CREATE ON DATABASE … TO "<app_user>"` also works.)

`<app_user>` / `<database>` are the username and database in your `DATABASE_URL`.
The schema name is overridable with `EVENT_STORE_SCHEMA`.

Both steps are **idempotent** and safe to run on every boot. `migrate/0` is
deliberately robust for a small managed DB: the migration uses a tiny pool with
long queue/connect timeouts and retries with backoff on transient failures
(connection crunch, or a migration-lock **deadlock**).

**One migrator, on boot.** There is intentionally **no PRE_DEPLOY migrate job** —
two migrators (a job plus the booting instance) contend on the `schema_migrations`
migration lock and can deadlock. Instead the web service runs `migrate/0` at
startup when `MIGRATE_ON_BOOT=true` (the spec default), before it serves, so the
schema is guaranteed present. Once migrations are applied, later boots are a fast
no-op. Set `MIGRATE_ON_BOOT=false` only if you move migrations elsewhere. To run it
by hand, open the web component's console and run `bin/migrate`.

> **If you created the app from an older spec** that still has the `migrate`
> PRE_DEPLOY job, delete that job from the app (DO console → the job component, or
> re-sync with `doctl apps update --spec .do/app.yaml`) — otherwise it and the
> boot migrator race.

## Database connection budget

DO's **dev-tier** managed Postgres caps total connections low (~20, with a few
reserved for the superuser role). The app must fit under that cap or queries fail
with `FATAL 53300 (too_many_connections) ... reserved for roles with the SUPERUSER
attribute` — which surfaces as a 500 on any page that touches the DB (e.g. `/signup`
querying the account count) while DB-free pages still render.

The connection consumers, per running instance:

- `POOL_SIZE` — the read-model Repo pool (spec default **5**).
- `EVENT_STORE_POOL_SIZE` — the event store pool (spec default **2**).
- a couple more for the eventstore's `LISTEN` notifier and Oban's notifier.

That's ~10 connections per instance. Watch two multipliers: a rolling deploy runs
the **old and new instance together** briefly (2×), and `instance_count > 1`
multiplies further. If you raise `instance_count`, add traffic, or want bigger
pools, move off the dev DB to a plan with a higher connection limit and raise
`POOL_SIZE` accordingly.

`Polyphony.ShutdownHook` helps here: on shutdown it terminates first and releases
the Repo connections **early**, so an outgoing instance frees its slots at the
start of the shutdown window instead of the end (`drain_on_shutdown`, on in prod).
This only helps a **graceful** shutdown (SIGTERM) — a hard SIGKILL or a crash can't
run cleanup, so those connections linger until the server reaps the dead sockets
(minutes). If you still see `no connection available` after that, the dev DB's slot
cap is simply too tight for a rolling deploy — bump the DB plan.

## LiveView socket / origin check (dead buttons)

If pages render but **every button does nothing** — sign-up, send-turn, everything
— the LiveView websocket is being rejected. The tell is in the logs:

```
[error] Could not check origin for Phoenix.Socket transport.
Origin of the request: https://<your-app>.ondigitalocean.app
```

Phoenix only accepts a socket whose `Origin` matches the endpoint's configured host
(`PHX_HOST`). When `PHX_HOST` is wrong — e.g. `${APP_DOMAIN}` didn't resolve to the
domain you're actually browsing — the socket is refused and the page falls back to
inert, server-less HTML.

- **Fix (spec default).** `.do/app.yaml` sets `CHECK_ORIGIN=//*.ondigitalocean.app`,
  which accepts this app's default domain regardless of how `${APP_DOMAIN}` resolves.
  Redeploy and the socket connects.
- **Custom domain.** Set `CHECK_ORIGIN` to your exact origin(s), comma-separated
  (`https://app.example.com,https://www.example.com`), and set `PHX_HOST` to the same
  host (it also drives generated URLs / magic links). `CHECK_ORIGIN=false` disables
  the check entirely — bring-up only, never public.
- **Confirm it.** Every boot logs
  `[boot] endpoint host=… check_origin=…` (visible in the debug drawer, see below) —
  check that `host` is the domain you're browsing.
- **In the browser**, the debug drawer's socket-status dot goes 🟢 green once the
  socket connects; 🔴 red is the same diagnosis from the client side.

## First smoke test after deploy

Once the app is live, confirm the whole stack — auth, DB, event store, and real
generation — end to end:

1. **App is up.** Open `https://<app-domain>/` — the home page renders (health check
   is green in the DO dashboard). If it's down, check the `migrate` job logs first
   (a failed migration blocks the deploy).
2. **Sign up → superadmin.** Sign up with your email. In prod the magic link is
   emailed (dev surfaces it on the page); the **first account becomes superadmin**.
   Signing in proves the session + `users` read model.
3. **Author a character + world.** Create a world bible and a character from the
   Library. Character/world generation uses the **heavy** model — a good first
   exercise of `DEEPINFRA_MODEL_HEAVY`.
4. **Run a scene.** Start a campaign, open a scene, send a turn, and hit **Continue
   (Director)** to let the autonomous cast take a beat. Real prose = the workhorse
   model, the Oban beat loop, and the persistent event store all working.
5. **If generation fails**, it surfaces in the UI as a retryable/editable failure
   (the `Failures` subsystem) rather than a crash. The usual first cause is a wrong
   **model id** (DeepInfra 404) — fix `DEEPINFRA_MODEL` / `DEEPINFRA_MODEL_HEAVY`
   and retry. Check the runtime logs for the DeepInfra response body.
   - **Unexpected 500s** (with `SHOW_ERROR_DETAILS=true`) now render the full
     exception + stacktrace in the browser, plus a request id — so you rarely need
     the logs during bring-up. Turn the flag off before opening the app publicly.
   - **Watch the server live from the browser.** Set `DEBUG_DRAWER=true` to get a
     floating **debug drawer** (bottom-right, on every page) that streams recent
     server logs with **Copy** and **Clear** — invaluable when a click seems to do
     nothing (you can see whether it even reached the server, e.g. the `[signup]`
     lines). It exposes raw logs, so set it back to `false` before the app is
     public. The drawer also shows a **socket-status** indicator (a dot on the
     collapsed toggle, a labelled pill when open): green = connected, amber =
     connecting, red = disconnected. It's driven by client JS, so it works even
     when the socket is down. If a **button does nothing, no log line appears, and
     the status is red**, the LiveView socket isn't connecting — check the logs for
     a `check_origin` rejection (`PHX_HOST` must match the app domain).
6. **Persistence check.** Redeploy (or restart the app) and confirm the scene is
   still there — that's the persistent event store surviving a restart, the whole
   reason prod isn't on the in-memory adapter.

## Ongoing deploys (CD)

`deploy.yml` runs on a `v*` tag or manual dispatch and calls:

```bash
doctl apps update "$DO_APP_ID" --spec .do/app.yaml --wait
```

App Platform rebuilds the Docker image, runs the `migrate` job, and rolls the web
service. `deploy_on_push` is off in the spec so ordinary pushes never deploy.

## Local release check (no Docker needed)

The release can be exercised on the modern toolchain to validate the prod path:

```bash
MIX_ENV=prod mix assets.deploy          # minify + digest assets
MIX_ENV=prod mix release                # assemble bin/polyphony
SECRET_KEY_BASE=… DATABASE_URL=… PHX_HOST=localhost PORT=4001 \
  _build/prod/rel/polyphony/bin/polyphony eval "Polyphony.Release.migrate()"
SECRET_KEY_BASE=… DATABASE_URL=… PHX_HOST=localhost PORT=4001 \
  _build/prod/rel/polyphony/bin/polyphony start
```

The endpoint binds `0.0.0.0` on `$PORT`. This same path — release assemble, boot +
serve, and `migrate` creating the `public` read models and the `eventstore` schema —
is what backs the "verified" status above.

## CI/CD workflows

- **`ci.yml`** — every push/PR on OTP 27 / Elixir 1.17: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, an asset-drift guard (`assets.setup` +
  `assets.build` + `git diff --exit-code`), then `mix test` against a pgvector
  Postgres service. Offline LLM providers.
- **`deploy.yml`** — on manual dispatch or a `v*` tag: `doctl apps update` syncs
  `.do/app.yaml`.
