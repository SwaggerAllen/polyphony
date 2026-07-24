import Config

# The read-model repository (Postgres + pgvector). The event log itself lives
# in the Commanded event store (see :polyphony, Polyphony.App below).
config :polyphony,
  ecto_repos: [Polyphony.Repo]

# Register the pgvector Postgrex extension so `Pgvector.Ecto.Vector` columns
# (scene/summary embeddings, §8) round-trip. Per-env DB settings merge on top.
config :polyphony, Polyphony.Repo, types: Polyphony.PostgrexTypes

# Commanded application configuration. We default to the in-memory event store
# adapter so the domain core is runnable and testable without provisioning the
# EventStore Postgres schema. Swapping to the persistent adapter is a config
# change only:
#
#     config :polyphony, Polyphony.App,
#       event_store: [
#         adapter: Commanded.EventStore.Adapters.EventStore,
#         event_store: Polyphony.EventStore
#       ]
#
# (see §2 "Commanded + EventStore" — the boundary is intentionally kept thin so
# the persistent store can slot in without touching the aggregates.)
config :polyphony, Polyphony.App,
  event_store: [
    adapter: Commanded.EventStore.Adapters.InMemory,
    serializer: Commanded.Serialization.JsonSerializer
  ],
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

import_config "#{config_env()}.exs"
