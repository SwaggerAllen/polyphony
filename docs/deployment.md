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
- **A PRE_DEPLOY job migrates before each release goes live**, then the web service
  boots.

## Prerequisites

- A DigitalOcean account and [`doctl`](https://docs.digitalocean.com/reference/doctl/).
- A DeepInfra API key.
- Repo secrets for CD: `DIGITALOCEAN_ACCESS_TOKEN` (App Platform write), `DO_APP_ID`.

## DeepInfra integration

Generation goes through the provider boundary (`Polyphony.LLM.Provider`); the live
adapter is `Polyphony.LLM.DeepInfra` (Erlang `:httpc`). Configure via
`config :polyphony, :llm` (see `config/config.exs`):

- `provider: Polyphony.LLM.DeepInfra`
- `deepinfra: [base_url: "https://api.deepinfra.com", model: <workhorse>]`
- `models: %{workhorse: …, heavy: …}` — the workhorse MoE on the volume path, the
  heavy model reserved for character/world generation and the refusal model-swap.

Set **`DEEPINFRA_API_KEY`** as an App Platform secret. Nothing else leaves the box.

## First deploy

1. **Create the app from the spec:**

   ```bash
   doctl apps create --spec .do/app.yaml
   ```

   This provisions the `web` service, the `migrate` PRE_DEPLOY job, and the managed
   `db` (Postgres 16). Note the returned app id and set it as the `DO_APP_ID` repo
   secret for CD.

2. **Set secrets / env.** `.do/app.yaml` declares them; fill in the `SECRET` ones in
   the App Platform UI (or via `doctl`):

   | Var | Source |
   |-----|--------|
   | `SECRET_KEY_BASE` | `mix phx.gen.secret` (64 bytes) |
   | `DEEPINFRA_API_KEY` | your DeepInfra key |
   | `DATABASE_URL` | injected from the managed db (`${db.DATABASE_URL}`) |
   | `PHX_HOST` | injected app domain (`${APP_DOMAIN}`) |
   | `POOL_SIZE` / `EVENT_STORE_POOL_SIZE` | connection pools (defaults 10 / 5) |

3. **pgvector.** DO's managed Postgres 16 ships `pgvector`, and the read-model
   migration runs `CREATE EXTENSION IF NOT EXISTS vector;`, so the release-time
   migrate is enough. (If your cluster's role can't create extensions, enable it once
   from the DO console first.)

## Migrations & the event store on deploy

The PRE_DEPLOY job runs `bin/migrate`, which calls `Polyphony.Release.migrate/0`:

1. runs pending read-model Ecto migrations (`public` schema), then
2. creates the `eventstore` schema if absent (over the existing `DATABASE_URL`
   connection — no `CREATE DATABASE`), and initializes/upgrades the event store
   tables.

Both steps are **idempotent**, so it is safe on every deploy. This is the only place
the event store schema is provisioned; the web service then boots with the
persistent adapter (`config/config.exs` selects it in prod).

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
