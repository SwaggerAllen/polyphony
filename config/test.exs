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

config :logger, level: :warning
