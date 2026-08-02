import Config

# Runtime (env-var) configuration — read at boot, not compile. Prod only.
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is not set (generate with `mix phx.gen.secret`)."

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Origin check for the LiveView websocket. By default the socket only accepts a
  # connection whose Origin matches the configured host (PHX_HOST). If PHX_HOST is
  # wrong or the platform's host is dynamic, the socket refuses every connection
  # ("Could not check origin for Phoenix.Socket transport") and **every LiveView
  # button goes dead** while pages still render. `CHECK_ORIGIN` is the escape hatch:
  #   • unset  → accept the configured host over http/https (the correct fix is a
  #              correct PHX_HOST);
  #   • a comma-separated list (e.g. "https://app.example.com,//*.example.com");
  #   • "false" → disable the check (bring-up only — do not ship public);
  #   • "true"  → the framework default (check against PHX_HOST).
  # See docs/deployment.md.
  check_origin =
    case System.get_env("CHECK_ORIGIN") do
      blank when blank in [nil, ""] -> ["https://#{host}", "http://#{host}"]
      "true" -> true
      "false" -> false
      origins -> origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :polyphony, PolyphonyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Bind all IPv4 interfaces. App Platform routes to the container over IPv4, and
    # 0.0.0.0 binds everywhere without depending on IPv6 being available.
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: check_origin,
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
  # models (same DATABASE_URL), isolated in its own schema (default `eventstore`).
  # Creating that schema needs CREATE on the database; on a managed DB where the app
  # user lacks it, pre-create the schema as the admin and grant the app user rights
  # (see docs/deployment.md). Override the name with EVENT_STORE_SCHEMA. A separate,
  # smaller pool keeps event appends from contending with read-model queries.
  config :polyphony,
         Polyphony.EventStore,
         [
           url: database_url,
           schema: System.get_env("EVENT_STORE_SCHEMA", "eventstore"),
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

  embed_model =
    System.get_env("DEEPINFRA_EMBED_MODEL") || deepinfra[:embed_model] ||
      "BAAI/bge-large-en-v1.5"

  # Surface full exception + stacktrace on 5xx pages during bring-up. Defaults on;
  # set SHOW_ERROR_DETAILS=false before the app is public (stacktraces leak
  # internals). See PolyphonyWeb.ErrorHTML.
  config :polyphony,
         :show_error_details,
         System.get_env("SHOW_ERROR_DETAILS", "true") in ~w(true 1)

  # Migrate + set up the event store on boot so the schema is guaranteed present,
  # independent of the pre-deploy migrate job. Idempotent. Set MIGRATE_ON_BOOT=false
  # to rely solely on the pre-deploy job (e.g. to keep boots fast at scale).
  config :polyphony,
         :migrate_on_boot,
         System.get_env("MIGRATE_ON_BOOT", "true") in ~w(true 1)

  # One-shot cleanup of a failed sign-up bootstrap on boot: if no account has
  # completed sign-up, delete any partial user rows a crash left behind so the very
  # next sign-up can bootstrap the superadmin cleanly. Off by default — set
  # RESET_INCOMPLETE_BOOTSTRAP=true for a single deploy, then remove it. See
  # Polyphony.Accounts.clean_incomplete_bootstrap/1.
  config :polyphony,
         :reset_incomplete_bootstrap,
         System.get_env("RESET_INCOMPLETE_BOOTSTRAP", "false") in ~w(true 1)

  # Floating debug drawer that streams recent server logs into the browser (copy +
  # clear). Invaluable during bring-up — you can watch what the server does on a
  # click without SSH. Off by default; it exposes raw logs, so set DEBUG_DRAWER=true
  # only while diagnosing and turn it off before the app is public.
  config :polyphony,
         :debug_drawer,
         System.get_env("DEBUG_DRAWER", "false") in ~w(true 1)

  # The component catalogue at /storybook. Off by default outside dev: it's a
  # review surface for the design kit, not part of the product. It exposes no
  # domain data, so turning it on is a presentation choice rather than a risk.
  config :polyphony, :storybook, System.get_env("STORYBOOK", "false") in ~w(true 1)

  config :polyphony, :llm,
    provider: Polyphony.LLM.DeepInfra,
    deepinfra: [
      base_url:
        System.get_env("DEEPINFRA_BASE_URL") || deepinfra[:base_url] ||
          "https://api.deepinfra.com",
      api_key: System.get_env("DEEPINFRA_API_KEY"),
      model: workhorse,
      embed_model: embed_model
    ],
    models: %{workhorse: workhorse, heavy: heavy}

  # Real embeddings in prod (dev/test stay on the offline MockEmbedder). Shares the
  # DeepInfra connection config above; ⚠ the embed model must be 1024-dim to match
  # the summary embedding column (see config/config.exs).
  config :polyphony, :embedder, Polyphony.SceneClose.DeepInfraEmbedder
end
