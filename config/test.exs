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

# Don't run the shutdown connection-drainer in tests (it would touch the SQL
# sandbox at suite teardown). It's a managed-DB deploy optimization.
config :polyphony, drain_on_shutdown: false

# Deterministic, network-free provider for tests.
config :polyphony, :llm, provider: Polyphony.LLM.Stub

# Cold-cache context rebuilds (character + Director brief) use the DB-free static
# retriever in tests, so a rebuild triggered off the test process (e.g. inside a RunBeat
# Oban job) doesn't reach for pgvector through a sandbox it can't see. Tests that assert
# on real pgvector retrieval call `materialize` with `PgvectorRetriever` explicitly.
config :polyphony, :rebuild_retriever, Polyphony.Context.StaticRetriever

# The endpoint serves in tests so the Wallaby feature tests can drive it over a
# real browser; the in-process LiveView/Conn tests ignore the listener. The SQL
# sandbox plug (enabled below) lets a browser request share the test's sandboxed
# DB connection.
config :polyphony, PolyphonyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-0000000000000000000000000000000000000000000000",
  server: true

# Real-browser feature tests (Wallaby). Tagged :feature and excluded from the
# default run (see test/test_helper.exs); run them with `mix test --only feature`.
# Chromedriver/Chromium paths default to the SessionStart-provisioned locations and
# can be overridden by env for other machines.
config :polyphony, :sql_sandbox, true

# Locate the browser + driver: env overrides win, else auto-detect the
# SessionStart-provisioned Chromium (glob tolerates the build-number suffix) and a
# `chromedriver` on PATH. `bin/setup-chromedriver` installs a matching driver.
chrome_binary =
  System.get_env("WALLABY_CHROME_BINARY") ||
    Path.wildcard("/opt/pw-browsers/chromium-*/chrome-linux/chrome") |> List.first()

chromedriver_path =
  System.get_env("WALLABY_CHROMEDRIVER") ||
    Enum.find(["/opt/chromedriver/bin/chromedriver"], &File.exists?/1) ||
    System.find_executable("chromedriver") ||
    "/opt/chromedriver/bin/chromedriver"

config :wallaby,
  otp_app: :polyphony,
  base_url: "http://localhost:4002",
  # Don't echo the browser's LiveView console logs into test output.
  js_logger: false,
  driver: Wallaby.Chrome,
  chromedriver: [
    path: chromedriver_path,
    binary: chrome_binary,
    headless: true
  ]

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
