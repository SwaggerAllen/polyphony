import Config

# Runtime (env-var) configuration — read at boot, not compile. Prod only.
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is not set (generate with `mix phx.gen.secret`)."

  # The host every generated URL is built from — `url/1`, and so the emailed magic
  # link. Sign-in is magic-link only, so this is not merely cosmetic: a wrong host
  # sends a working token to a machine the recipient does not have, and it fails
  # **silently**, because every page still renders and only the link is dead.
  #
  # `PHX_HOST` is the setting. App Platform publishes the app's own domain as
  # `APP_DOMAIN` (and the same thing URL-shaped as `APP_URL`), so an unset PHX_HOST
  # falls back to those before `localhost` — which is never the right answer in prod,
  # and is the one value that cannot be a deliberate choice here.
  # Reads a host out of any of the three, and copes with the two ways they arrive
  # wrong: **blank** (`${APP_DOMAIN}` that expanded to nothing — `"" || "localhost"` is
  # `""` in Elixir, so a bare `||` chain would keep it and generate `https:///…`), and
  # **a whole URL** where a host belongs, which otherwise yields
  # `https://https://app.example.com/…` in every link.
  read_host = fn value ->
    case String.trim(value || "") do
      "" ->
        nil

      trimmed ->
        with_scheme = if String.contains?(trimmed, "//"), do: trimmed, else: "//" <> trimmed

        case URI.parse(with_scheme) do
          %URI{host: found} when is_binary(found) and found != "" -> found
          _ -> nil
        end
    end
  end

  host =
    read_host.(System.get_env("PHX_HOST")) || read_host.(System.get_env("APP_DOMAIN")) ||
      read_host.(System.get_env("APP_URL")) || "localhost"

  # Loud, because the quiet version of this is a sign-in page that works, sends mail
  # that arrives, and hands over a link to nowhere.
  if host in ~w(localhost 127.0.0.1 0.0.0.0 ::1) do
    IO.puts(
      "[boot] WARNING PHX_HOST is unset — every URL this node generates points at " <>
        "#{host}. Sign-in is magic-link only, so the emailed link is unusable and " <>
        "nobody can sign in. CHECK_ORIGIN fixes the websocket, not the links."
    )
  end

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

  # Crash reporting. Unset means off, and off is a real deploy state rather than a
  # misconfiguration — the app runs, it just can't tell you it broke, which is exactly
  # the situation STR-55 describes and worth being able to see in one variable.
  #
  # `release:` ties a report to the commit that produced it. App Platform has no
  # variable of its own for this — `SOURCE_COMMIT` does not exist there, whatever it
  # looks like it should be called — so `.do/app.yaml` binds `SENTRY_RELEASE` to the
  # platform's `${_self.COMMIT_HASH}`. Unset is fine: reports still arrive, they just
  # can't say which build produced them.
  if dsn = System.get_env("SENTRY_DSN") do
    config :sentry,
      dsn: dsn,
      release: System.get_env("SENTRY_RELEASE")

    IO.puts("[boot] crash reporting ON (Sentry) — payloads go through Polyphony.Redact")
  else
    IO.puts("[boot] crash reporting OFF — set SENTRY_DSN to turn it on")
  end

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

  # ── Email (§B4) ──────────────────────────────────────────────────────────────
  #
  # Sign-in is magic-link only, so **mail is the front door**: with no mailer
  # configured nobody can log in at all. Configured entirely from env vars, and only
  # switched on when SMTP_HOST and MAIL_FROM are both present — a half-configured
  # mailer stays on the logging transport, where a delivery is recorded rather than
  # silently dropped.
  #
  # SMTP rather than a provider API on purpose: Resend, Postmark, SendGrid, Mailgun
  # and SES all speak it, so the choice of provider is a credential rather than a
  # deploy. Port 587 with STARTTLS is what every one of them wants; 465 (implicit TLS)
  # is picked up from the port alone.
  # A relay is a **hostname**, never `host:port` — gen_smtp hands the string straight
  # to DNS, so `smtp.postmarkapp.com:587` resolves to nothing and fails as `:nxdomain`,
  # an error that names DNS rather than the configuration mistake. Providers publish their SMTP
  # settings as "server: X, ports: 25/587/2525", which invites exactly that paste, so
  # a port on the host is split off and used rather than rejected.
  {smtp_host, host_port} =
    case String.split(System.get_env("SMTP_HOST") || "", ":", parts: 2) do
      [host, port] -> {String.trim(host), String.trim(port)}
      [host] -> {String.trim(host), nil}
    end

  # Explicit SMTP_PORT wins; then a port found on the host; then 587, the submission
  # port every provider offers. **Not 25**: it is for server-to-server relay, and most
  # hosts — App Platform included — block it outbound.
  smtp_port = String.to_integer(System.get_env("SMTP_PORT") || host_port || "587")

  # Which of the two TLS shapes the port speaks. 465 is implicit TLS — the connection
  # is encrypted from the first byte — while 25/587/2525 open in the clear and upgrade
  # with STARTTLS. That mapping is the same at every provider, so it is derived rather
  # than made a second thing to keep in sync; SMTP_SSL still overrides. Getting the
  # pair wrong is silent in the worst way: plaintext at 465 makes the relay hang up
  # without a word, which surfaces as `{:network_failure, …, {:error, :closed}}` and
  # reads like a network fault.
  smtp_ssl =
    case System.get_env("SMTP_SSL") do
      blank when blank in [nil, ""] -> smtp_port == 465
      value -> value in ~w(true 1)
    end

  mail_from = System.get_env("MAIL_FROM")

  # No provider? Capture mail in memory and let it be read at `/dev/mailbox`, behind
  # HTTP Basic auth from `MAILBOX_USER` / `MAILBOX_PASSWORD`.
  #
  # Basic auth rather than `require_admin`, and that is the whole design: the moment
  # you need to read a sign-in link is the moment you are *not* signed in, so an
  # admin gate would lock the door with the key inside. Unset means the route 404s.
  #
  # ⚠ Anyone with these credentials can read every magic link this node has sent, which
  # is every account. It is a single-operator bring-up affordance, not a feature — set
  # a real password, and prefer a provider once anyone else has an account.
  mailbox_password = System.get_env("MAILBOX_PASSWORD")

  if smtp_host in [nil, ""] and mailbox_password not in [nil, ""] do
    config :polyphony, Polyphony.Mailer, adapter: Swoosh.Adapters.Local
    config :polyphony, :mail_from, mail_from || "polyphony@localhost"
    config :polyphony, :notification_transport, Polyphony.Notifications.Transport.Email

    config :polyphony, :mailbox_auth,
      username: System.get_env("MAILBOX_USER") || "polyphony",
      password: mailbox_password

    IO.puts("[boot] mail captured in memory; readable at /dev/mailbox (basic auth)")
  end

  if smtp_host not in [nil, ""] and mail_from not in [nil, ""] do
    # Verify the relay's certificate against the system CA bundle. `:verify_none` is
    # the gen_smtp default and would hand the credentials to anyone who can answer for
    # the host.
    smtp_tls_options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(smtp_host),
      depth: 3,
      # Without this, `verify_peer` rejects a perfectly valid wildcard certificate.
      # Erlang's default hostname check is strict RFC 6125 and does **not** match
      # `*.postmarkapp.com` against `smtp.postmarkapp.com`; the `:https` match fun is
      # the ordinary browser rule (one wildcard, leftmost label only). Providers
      # almost always serve a wildcard, so verification is unusable without it — and
      # the failure reads as `:tls_failed` / `hostname_check_failed`, which sounds
      # like a bad certificate rather than a missing option.
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    # Omitted rather than set to nil when absent: Swoosh type-checks these two and
    # **raises** on a non-binary, so an unset SMTP_USERNAME would turn every send into
    # an ArgumentError out of the LiveView rather than a delivery error the sign-in
    # screen can report.
    #
    # Trimmed for the same reason SMTP_HOST is: these are pasted into a hosting
    # dashboard, and a trailing newline is invisible there and fatal here — the relay
    # answers a whitespace-padded API key with a 535 that says the key is invalid,
    # which sends you back to the provider to re-issue a key that was fine.
    smtp_credentials =
      for key <- [:username, :password],
          value = System.get_env("SMTP_#{String.upcase(to_string(key))}"),
          value = String.trim(value),
          value != "",
          do: {key, value}

    config :polyphony,
           Polyphony.Mailer,
           [
             adapter: Swoosh.Adapters.SMTP,
             relay: smtp_host,
             port: smtp_port,
             ssl: smtp_ssl,
             # `:always` demands a STARTTLS upgrade — but a socket that is *already*
             # TLS never advertises STARTTLS, and gen_smtp answers that with
             # `{:missing_requirement, :tls}`. The two modes are mutually exclusive,
             # not additive.
             tls: if(smtp_ssl, do: :never, else: :always),
             tls_options: smtp_tls_options,
             # The same options again, through the other door. gen_smtp applies
             # `tls_options` **only** to the STARTTLS upgrade; an implicit-TLS
             # connection is handed `sockopts` instead, merged over defaults that carry
             # no CA store and `depth: 0`. On OTP 27 that is not "unverified but
             # working" — the client default is now `verify_peer`, so `ssl:connect/4`
             # refuses the options outright with `{:options, :incompatible, [verify:
             # :verify_peer, cacerts: :undefined]}`, and port 465 cannot connect at all
             # without this line.
             sockopts: if(smtp_ssl, do: smtp_tls_options, else: []),
             # Demanding AUTH we have no credentials for fails as `auth_failed`, which
             # reads as "wrong password" rather than "no password".
             auth: if(smtp_credentials == [], do: :never, else: :always),
             retries: 2,
             # A submission relay is connected to directly. Looking up MX records for it
             # asks "who accepts mail *for* this domain", which is a different question
             # and the wrong one — it costs a DNS round trip per send and, for a host
             # that does publish MX records, would send the mail somewhere else
             # entirely.
             no_mx_lookups: true
           ] ++ smtp_credentials

    # Postmark routes by **message stream**, and the header naming it is the difference
    # between a message landing on the transactional stream and landing somewhere you
    # aren't watching. Defaulted for a Postmark relay rather than for everyone, since
    # it is a vendor header; `POSTMARK_MESSAGE_STREAM` overrides for a custom stream.
    message_stream =
      System.get_env("POSTMARK_MESSAGE_STREAM") ||
        if String.ends_with?(smtp_host, "postmarkapp.com"), do: "outbound"

    if message_stream do
      config :polyphony, :mail_headers, %{"X-PM-Message-Stream" => message_stream}
    end

    config :polyphony, :mail_from, mail_from
    config :polyphony, :mail_from_name, System.get_env("MAIL_FROM_NAME") || "Polyphony"
    config :polyphony, :notification_transport, Polyphony.Notifications.Transport.Email

    IO.puts(
      "[boot] mail relay=#{smtp_host}:#{smtp_port} tls=#{if smtp_ssl, do: "implicit", else: "starttls"} " <>
        "from=#{mail_from} " <>
        "auth=#{if System.get_env("SMTP_USERNAME"), do: "set", else: "MISSING"}"
    )

    # Honoured, but said out loud. Both halves of this fail as a dropped connection
    # rather than as anything about TLS: plaintext at 465 gets hung up on, and a TLS
    # handshake at 587 is answered with a plaintext banner the client can't read.
    # The SMTP conversation, line by line, into the log — and so into the debug drawer,
    # which is the only way to read it from a phone. Worth a switch because gen_smtp
    # reports a refused send as one word: `:closed` before the banner means the relay
    # is refusing *us*, and `:closed` after AUTH means it is refusing the *message*,
    # and the error is identical either way. Off by default — it is a per-send log of a
    # network conversation, not something to leave running.
    if System.get_env("SMTP_TRACE", "false") in ~w(true 1) do
      config :polyphony, Polyphony.Mailer, trace_fun: &Polyphony.Mailer.trace/2
      IO.puts("[boot] mail SMTP tracing ON (SMTP_TRACE) — credentials are redacted")
    end

    if smtp_ssl != (smtp_port == 465) do
      IO.puts(
        "[boot] mail WARNING SMTP_SSL=#{smtp_ssl} with port #{smtp_port}. Implicit TLS " <>
          "is port 465; 25/587/2525 are STARTTLS. Unset SMTP_SSL to follow the port."
      )
    end

    # Not overridden — an explicit choice is honoured — but said out loud, because a
    # port 25 that arrived on the host rather than in SMTP_PORT is almost always a
    # paste rather than a decision, and it fails as a connection timeout that mentions
    # nothing about ports.
    if smtp_port == 25 do
      IO.puts(
        "[boot] mail WARNING port 25 is server-to-server relay and blocked outbound " <>
          "by most hosts, App Platform included. Submission is 587 (or 2525)."
      )
    end
  end
end
