import Config

# The read-model repository (Postgres + pgvector). The event log itself lives
# in the Commanded event store (see :polyphony, Polyphony.App below).
config :polyphony,
  ecto_repos: [Polyphony.Repo]

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

# Job dispatch (§2). Generation runs in Oban jobs — never in an aggregate
# (foundational rule 1) — so a job produces commands.
config :polyphony, Oban,
  repo: Polyphony.Repo,
  queues: [generation: 5, director: 2, scene_close: 3],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60}]

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
    model: "Qwen/Qwen3.5-35B-A3B"
  ],
  models: %{
    workhorse: "Qwen/Qwen3.5-35B-A3B",
    heavy: "Qwen/Qwen3.5-397B-A17B"
  }

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

# Asset build tooling. esbuild bundles the JS (resolving `phoenix` /
# `phoenix_live_view` from deps via NODE_PATH); Tailwind builds the CSS. Both run
# as standalone binaries — no Node.js toolchain required.
config :esbuild,
  version: "0.21.5",
  polyphony: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  polyphony: [
    args: ~w(--input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]

import_config "#{config_env()}.exs"
