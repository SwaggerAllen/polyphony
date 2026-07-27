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
- **`DEEPINFRA_MODEL`** — the **workhorse** model, used on every turn.
- **`DEEPINFRA_MODEL_HEAVY`** — reserved for character/world generation and the
  refusal model-swap (falls back to the workhorse if unset).
- `DEEPINFRA_BASE_URL` — optional; defaults to `https://api.deepinfra.com`.

> ⚠ **The model ids in `config/config.exs` are placeholders** (illustrative Qwen
> strings), so a deploy that doesn't set `DEEPINFRA_MODEL` will 404 on the first
> generation. Look up the exact model ids in your DeepInfra dashboard and set the
> two env vars before the first run. Everything else stays offline — nothing but
> the DeepInfra call leaves the box.

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
     public. If a **button does nothing and no log line appears**, the LiveView
     socket isn't connecting — check the logs for a `check_origin` rejection
     (`PHX_HOST` must match the app domain).
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
