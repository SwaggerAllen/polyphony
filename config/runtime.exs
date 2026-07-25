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

  # DO's managed Postgres requires SSL and hands you a URL ending in
  # `?sslmode=require`. Postgrex silently ignores that query param (so it would
  # connect unencrypted and get rejected), and the eventstore URL parser rejects it
  # outright — so strip the query string and enable SSL explicitly on both. Set
  # DATABASE_SSL=false to opt out (e.g. a local/non-SSL Postgres).
  database_url = database_url |> String.split("?") |> hd()
  database_ssl? = System.get_env("DATABASE_SSL") != "false"

  # `verify_none` encrypts without pinning DO's CA. To verify the server cert,
  # download DO's CA and set DATABASE_SSL_CACERTFILE to its path.
  ssl_opts =
    case System.get_env("DATABASE_SSL_CACERTFILE") do
      nil -> [verify: :verify_none]
      path -> [verify: :verify_peer, cacertfile: path]
    end

  db_ssl = if database_ssl?, do: [ssl: true, ssl_opts: ssl_opts], else: []

  config :polyphony,
         Polyphony.Repo,
         [url: database_url, pool_size: pool_size] ++ db_ssl

  # The persistent event store shares the managed Postgres cluster with the read
  # models (same DATABASE_URL), isolated in its own `eventstore` schema (set in
  # config/prod.exs). A separate, smaller connection pool keeps event appends from
  # contending with read-model queries.
  config :polyphony,
         Polyphony.EventStore,
         [
           url: database_url,
           pool_size: String.to_integer(System.get_env("EVENT_STORE_POOL_SIZE") || "5")
         ] ++ db_ssl

  # LLM provider (DeepInfra in prod). The connection + model are env-driven so a
  # deployment can be pointed at real DeepInfra models without a code change —
  # ⚠ the model ids in config/config.exs are PLACEHOLDERS; set DEEPINFRA_MODEL
  # (and DEEPINFRA_MODEL_HEAVY) to real DeepInfra model ids. Env overrides the
  # compile-time defaults; unset keys fall back to config/config.exs.
  llm = Application.get_env(:polyphony, :llm, [])
  deepinfra = Keyword.get(llm, :deepinfra, [])
  models = Keyword.get(llm, :models, %{})

  workhorse = System.get_env("DEEPINFRA_MODEL") || deepinfra[:model] || models[:workhorse]
  heavy = System.get_env("DEEPINFRA_MODEL_HEAVY") || models[:heavy] || workhorse

  config :polyphony, :llm,
    provider: Polyphony.LLM.DeepInfra,
    deepinfra: [
      base_url:
        System.get_env("DEEPINFRA_BASE_URL") || deepinfra[:base_url] ||
          "https://api.deepinfra.com",
      api_key: System.get_env("DEEPINFRA_API_KEY"),
      model: workhorse
    ],
    models: %{workhorse: workhorse, heavy: heavy}
end
