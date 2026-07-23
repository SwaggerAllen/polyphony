import Config

# The read-model repository (Postgres + pgvector). The event log itself lives
# in the Commanded event store (see :polyphony, Polyphony.App below).
config :polyphony,
  ecto_repos: [Polyphony.Repo]

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

import_config "#{config_env()}.exs"
