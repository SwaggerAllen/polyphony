import Config

config :polyphony, Polyphony.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "polyphony_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# Oban runs in manual testing mode — jobs are enqueued but only executed when a
# test drains them (Oban.Testing).
config :polyphony, Oban, testing: :manual

# Don't start the live Ecto projector process in tests; the read model's SQL is
# exercised directly, and visibility integration tests derive membership from the
# stored event stream (MembershipSet). Keeps Commanded dispatch off the sandbox.
config :polyphony, start_projectors: false

# Deterministic, network-free provider for tests.
config :polyphony, :llm, provider: Polyphony.LLM.Stub

# Endpoint runs without a listening server in tests; LiveView tests drive it in-process.
config :polyphony, PolyphonyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-0000000000000000000000000000000000000000000000",
  server: false

# Persistent event store config for `Polyphony.PersistentEventStoreTest` only.
# Inert during the normal suite (nothing starts `Polyphony.EventStore` — the app
# runs on the in-memory adapter); that one test starts `Polyphony.PersistentApp`,
# which uses these to exercise the prod event-store path against a dedicated
# `eventstore_test` schema in the test database.
test_db = "polyphony_test#{System.get_env("MIX_TEST_PARTITION")}"

config :polyphony, Polyphony.EventStore,
  serializer: Commanded.Serialization.JsonSerializer,
  column_data_type: "jsonb",
  schema: "eventstore_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: test_db,
  pool_size: 2

config :polyphony, event_stores: [Polyphony.EventStore]

config :polyphony, Polyphony.PersistentApp,
  event_store: [
    adapter: Commanded.EventStore.Adapters.EventStore,
    event_store: Polyphony.EventStore
  ],
  pubsub: :local,
  registry: :local

config :logger, level: :warning
