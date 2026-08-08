import Config

# The read-model repository (Postgres + pgvector). The event log itself lives
# in the Commanded event store (see :polyphony, Polyphony.App below).
config :polyphony,
  ecto_repos: [Polyphony.Repo]

# Whether the sign-in screen may print the magic link on the page instead of relying
# on email. **Never true in prod** — printing it means anyone who types a known
# address gets a working 15-minute session for that account.
#
# It is a named policy flag rather than an env comparison at the call site, and it is
# read with a `:prod`-safe default, because the version this replaced asked
# `Application.get_env(:polyphony, :env) == :prod` about a key nothing ever set: the
# comparison was false everywhere, so the guard failed *open* and shipped the link in
# production. A flag that has to be switched on can only fail closed.
config :polyphony, :expose_magic_link, config_env() != :prod

# Swoosh talks SMTP here, not a provider HTTP API, so it needs no API client — saying
# so explicitly stops it requiring Finch/Hackney we don't otherwise carry.
config :swoosh, :api_client, false

# Register the pgvector Postgrex extension so `Pgvector.Ecto.Vector` columns
# (scene/summary embeddings, §8) round-trip. Per-env DB settings merge on top.
config :polyphony, Polyphony.Repo, types: Polyphony.PostgrexTypes

# Commanded application configuration. The event store adapter is chosen per
# environment: dev/test run on the **in-memory** adapter (no Postgres schema to
# provision — the domain core stays offline and the whole suite runs against it),
# while **prod** uses the persistent EventStore adapter so the event log (the
# single source of truth) survives restarts and deploys. The aggregates are
# identical either way — §2 keeps the store boundary thin on purpose. The prod
# EventStore's connection + schema are configured in config/prod.exs and
# config/runtime.exs.
event_store_adapter =
  if config_env() == :prod do
    [
      adapter: Commanded.EventStore.Adapters.EventStore,
      event_store: Polyphony.EventStore
    ]
  else
    [
      adapter: Commanded.EventStore.Adapters.InMemory,
      serializer: Commanded.Serialization.JsonSerializer
    ]
  end

config :polyphony, Polyphony.App,
  event_store: event_store_adapter,
  pubsub: :local,
  registry: :local

# What an event is stored *as*. Commanded's default writes the Elixir module name into
# `event_type`, which quietly makes every module path part of the stored data — a rename
# then orphans every row already written, and a suite that only round-trips fresh events
# cannot see it happen. `PolyphonyCore.Events.TypeProvider` writes stable names instead,
# and still reads both historical module-name spellings. This is global `:commanded`
# config, not per-application: it applies to the in-memory adapter in dev/test and to the
# persistent store in prod, which is what makes the fixtures in `TypeProviderTest`
# meaningful in every env.
config :commanded, type_provider: PolyphonyCore.Events.TypeProvider

# Job dispatch (§2). Generation runs in Oban jobs — never in an aggregate
# (foundational rule 1) — so a job produces commands.
config :polyphony, Oban,
  repo: Polyphony.Repo,
  queues: [generation: 5, director: 2, scene_close: 3, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60},
    # The recovery window is only a number rather than a claim if something actually
    # purges on schedule (§2.13). Daily is enough for a 30-day window, and the job is
    # idempotent, so a missed run catches up on the next one.
    {Oban.Plugins.Cron,
     crontab: [
       {"0 4 * * *", Polyphony.Jobs.PurgeTrash},
       {"20 4 * * *", Polyphony.Jobs.PurgeAccounts}
     ]}
  ]

# LLM provider config (§2, §3). DeepInfra direct by default; the workhorse MoE
# on the volume path, the heavy model reserved for character/world generation.
#
# ⚠ PLACEHOLDER MODEL IDS. The strings below are illustrative, not verified
# against DeepInfra's live catalog — a deploy will 404 until they're real. In
# prod, set them from env (DEEPINFRA_MODEL / DEEPINFRA_MODEL_HEAVY, see
# config/runtime.exs) rather than editing here; dev/test never call DeepInfra.
config :polyphony, :llm,
  provider: Polyphony.LLM.DeepInfra,
  deepinfra: [
    base_url: "https://api.deepinfra.com",
    model: "Qwen/Qwen3.5-35B-A3B",
    # Embedding model for pgvector summaries (§8). 1024-dim = the embedding column
    # size; a different-dimension model is a migration. Overridable via
    # DEEPINFRA_EMBED_MODEL. Only used in prod — dev/test embed with MockEmbedder.
    embed_model: "BAAI/bge-large-en-v1.5"
  ],
  models: %{
    workhorse: "Qwen/Qwen3.5-35B-A3B",
    heavy: "Qwen/Qwen3.5-397B-A17B"
  }

# Per-campaign LLM tuning (Director thinking + token budgets) lives on the campaign,
# not in env — see `Polyphony.LLM.Settings`, edited from the campaign screen.

# Embedding provider. Defaults to the offline deterministic mock everywhere; prod
# swaps in the real DeepInfra embedder in config/runtime.exs.
config :polyphony, :embedder, Polyphony.SceneClose.MockEmbedder

# Spend accounting (§B5). `micro_cents_per_1k_tokens` sets the estimated cost rate
# every metered LLM call (`Polyphony.LLM`) books into the ledger; the caps guard
# runaway generation (see `Polyphony.Costs` for the defaults). Placeholder rate —
# tune once real per-model pricing is wired.
config :polyphony, :costs, micro_cents_per_1k_tokens: 100

# Moderation → notification wiring (§B3 → §B4): route the one live notification wire
# (admin report alerts) through the sending path. Email transport defaults to the
# logging adapter until a real email adapter is configured. Tests override locally.
config :polyphony, :moderation_notifier, Polyphony.Notifications.ModerationNotifier

# Web endpoint (LiveView frontend). secret_key_base is a fixed dev/test value here
# and overridden from the environment in prod (runtime.exs).
config :polyphony, PolyphonyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [formats: [html: PolyphonyWeb.ErrorHTML], layout: false],
  pubsub_server: Polyphony.PubSub,
  live_view: [signing_salt: "polyphonyLVsalt01"],
  secret_key_base: "dev-only-secret-key-base-please-override-in-prod-0000000000000000000000"

config :phoenix, :json_library, Jason

# Show the full exception + stacktrace on 5xx error pages (PolyphonyWeb.ErrorHTML).
# Off by default; prod turns it on from SHOW_ERROR_DETAILS (runtime.exs) during
# bring-up. Dev shows the richer Plug.Debugger page instead (debug_errors: true).
config :polyphony, :show_error_details, false

# Crash reporting (STR-55). **No DSN means no reporting**, which is the state in dev and
# test and in any deploy that hasn't set one — `Polyphony.Crash.enabled?/0` reads the DSN
# rather than a flag of its own, so there is no way to be switched on with nowhere to
# send. `runtime.exs` supplies the DSN from SENTRY_DSN.
#
# `before_send` is not optional decoration: it is the last thing that runs before a
# payload leaves the box, and the only place with the whole event in hand. See
# `Polyphony.Redact` for what it strips and — just as deliberately — what it keeps.
config :sentry,
  dsn: nil,
  client: Polyphony.Crash.HTTP,
  before_send: {Polyphony.Crash, :before_send},
  environment_name: to_string(config_env()),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  # A job that exhausts its retries currently ends in a table nobody watches. This is
  # the other half of the same gap `SafeEvent` was: the failure is recorded where the
  # code can see it and nowhere a person can.
  integrations: [oban: [capture_errors: true]]

# Run migrations + event-store setup at boot (Polyphony.Application). Off by
# default; prod turns it on from MIGRATE_ON_BOOT (runtime.exs) so the schema is
# self-healing regardless of the pre-deploy migrate job. dev/test manage their own.
config :polyphony, :migrate_on_boot, false

# One-shot cleanup of a failed sign-up bootstrap on boot (RESET_INCOMPLETE_BOOTSTRAP
# in prod). Off by default — see Polyphony.Accounts.clean_incomplete_bootstrap/1.
config :polyphony, :reset_incomplete_bootstrap, false

# Floating debug drawer (PolyphonyWeb.DebugDrawerLive) that streams recent server
# logs to the browser with copy/clear — a bring-up aid. Off by default; dev turns it
# on, prod from DEBUG_DRAWER (runtime.exs). Exposes raw logs, so keep it off in
# public prod. See Polyphony.DebugLog.
config :polyphony, :debug_drawer, false

# Asset build tooling. esbuild bundles the JS (resolving `phoenix` /
# `phoenix_live_view` from deps via NODE_PATH); Tailwind builds the CSS. Both run
# as standalone binaries — no Node.js toolchain required.
config :esbuild,
  version: "0.21.5",
  polyphony: [
    args:
      ~w(js/app.js js/storybook.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  polyphony: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ],
  # The storybook loads its own bundle, not app.css (see assets/css/storybook.css).
  storybook: [
    args: ~w(--input=css/storybook.css --output=../priv/static/assets/storybook.css),
    cd: Path.expand("../assets", __DIR__)
  ]

# The component catalogue (PolyphonyWeb.Storybook) at /storybook. A review aid,
# not a product surface: on in dev, off elsewhere unless STORYBOOK=true
# (runtime.exs). It renders components only and reads no domain data.
config :polyphony, :storybook, false

import_config "#{config_env()}.exs"
