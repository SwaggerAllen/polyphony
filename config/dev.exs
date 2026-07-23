import Config

config :polyphony, Polyphony.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "polyphony_dev",
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Offline by default in dev: the lorem-ipsum Mock provider so the full loop runs
# without network. Set provider: Polyphony.LLM.DeepInfra (+ DEEPINFRA_API_KEY) to
# hit the real model.
config :polyphony, :llm, provider: Polyphony.LLM.Mock

config :logger, :console, level: :info
