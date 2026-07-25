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
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true

  config :polyphony, Polyphony.Repo,
    url: System.get_env("DATABASE_URL") || raise("DATABASE_URL is not set"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
