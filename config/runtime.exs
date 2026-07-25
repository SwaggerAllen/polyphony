import Config

# Runtime (env-var) configuration — read at boot, not compile. Prod only.
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is not set (generate with `mix phx.gen.secret`)."

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :polyphony, PolyphonyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Bind all IPv4 interfaces. App Platform routes to the container over IPv4, and
    # 0.0.0.0 binds everywhere without depending on IPv6 being available.
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  database_url = System.get_env("DATABASE_URL") || raise("DATABASE_URL is not set")
  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")

  config :polyphony, Polyphony.Repo,
    url: database_url,
    pool_size: pool_size

  # The persistent event store shares the managed Postgres cluster with the read
  # models (same DATABASE_URL), isolated in its own `eventstore` schema (set in
  # config/prod.exs). A separate, smaller connection pool keeps event appends from
  # contending with read-model queries.
  config :polyphony, Polyphony.EventStore,
    url: database_url,
    pool_size: String.to_integer(System.get_env("EVENT_STORE_POOL_SIZE") || "5")
end
