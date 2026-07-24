# Deployment — DigitalOcean App Platform + DeepInfra

How to run Polyphony in production on DigitalOcean App Platform, and how to point
generation at DeepInfra. CI/CD is in `.github/workflows/`.

> **Status.** CI (`ci.yml`) runs today: format, `--warnings-as-errors` compile, and
> the full suite against a pgvector Postgres. CD (`deploy.yml` + `.do/app.yaml`) is
> the **seam** — it deploys a Phoenix release that doesn't exist yet. The web layer
> and `mix release` land later (see `roadmap.md`); wire the secrets now and CD
> activates the moment the release is buildable.

## Prerequisites (for CD, when the web layer exists)

- A DigitalOcean account and [`doctl`](https://docs.digitalocean.com/reference/doctl/).
- A DeepInfra API key.
- Repo secrets: `DIGITALOCEAN_ACCESS_TOKEN` (App Platform write), `DO_APP_ID`.

## DeepInfra integration

Generation goes through the provider boundary (`Polyphony.LLM.Provider`); the live
adapter is `Polyphony.LLM.DeepInfra` (Erlang `:httpc`, no extra deps on the 1.14
toolchain). Configure via `config :polyphony, :llm` (see `config/config.exs`):

- `provider: Polyphony.LLM.DeepInfra`
- `deepinfra: [base_url: "https://api.deepinfra.com", model: <workhorse>]`
- `models: %{workhorse: …, heavy: …}` — the workhorse MoE on the volume path, the
  heavy model reserved for character/world generation and the refusal model-swap.

Set **`DEEPINFRA_API_KEY`** in the environment (App Platform secret). Nothing else
leaves the box — the app is otherwise self-contained.

## App Platform

1. **Create the managed database.** Postgres 16. Enable pgvector once:
   `CREATE EXTENSION IF NOT EXISTS vector;` (the app's migration also runs this, so
   a release-time migrate is enough). App Platform injects `DATABASE_URL`.
2. **Create the app** from the spec once the release exists:
   `doctl apps create --spec .do/app.yaml`, then set `DO_APP_ID` to the new id.
3. **Secrets / env** (`.do/app.yaml` lists them): `SECRET_KEY_BASE`
   (`mix phx.gen.secret`), `DEEPINFRA_API_KEY`, `DATABASE_URL` (from the managed db),
   `PHX_HOST`, `POOL_SIZE`.
4. **Migrations on deploy.** Run migrations from the release before boot — a
   `Polyphony.Release.migrate/0` invoked by the release start command, or a pre-deploy
   job. (Lands with the release work.)

## Event store note

The event log currently uses Commanded's **in-memory adapter** (config-only; the
domain runs without provisioning the EventStore schema). For a persistent
production deployment, switch `config :polyphony, Polyphony.App` to the persistent
`Commanded.EventStore.Adapters.EventStore` adapter and provision its schema in the
managed Postgres — see the commented block in `config/config.exs`. This is a prod
decision to make when the release is built; the aggregates don't change.

## CI/CD workflows

- **`ci.yml`** — on every push/PR: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix test` (pgvector Postgres service,
  offline providers). This is live now.
- **`deploy.yml`** — on manual dispatch or a `v*` tag: `doctl apps update` syncs
  `.do/app.yaml`. Activates once the release is buildable.
