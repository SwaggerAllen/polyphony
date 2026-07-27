defmodule Polyphony.Release do
  @moduledoc """
  Release tasks — run at deploy time (pre-deploy job) and, in prod, on boot
  (`Polyphony.Application`), from the built release (no Mix available).

  `migrate/0` is the entrypoint: it runs the read-model Ecto migrations and then
  creates/updates the persistent event store's schema and tables. Both steps are
  idempotent, so it is safe to run repeatedly.

  It is deliberately **patient**: the migration repo uses a tiny pool with long
  queue/connect timeouts, and the whole thing retries with backoff. On a small
  managed database (few connection slots) a deploy can briefly contend with the
  outgoing instance for connections; patience lets that clear instead of
  crash-looping the app.

  Invoke from the release, e.g.:

      bin/polyphony eval "Polyphony.Release.migrate()"

  See `docs/deployment.md`.
  """
  require Logger

  @app :polyphony

  # Minimal footprint + patience for a connection-constrained managed DB. The
  # migration only needs a connection or two; the long queue/connect timeouts let
  # it wait out a transient connection crunch rather than failing at ~6s.
  @migrate_opts [
    pool_size: 2,
    timeout: 120_000,
    connect_timeout: 30_000,
    queue_target: 10_000,
    queue_interval: 120_000
  ]

  @max_attempts 6

  @doc "Run read-model migrations, then create/upgrade the event store schema."
  def migrate do
    load_app()

    with_retry(fn ->
      migrate_read_models()
      setup_event_store()
    end)

    :ok
  end

  @doc "Run pending Ecto migrations for every read-model repo (patient pool/timeouts)."
  def migrate_read_models do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true), @migrate_opts)
    end
  end

  @doc """
  Create the event store's dedicated schema (if absent) and initialize/upgrade
  its tables. Does not attempt `CREATE DATABASE` — the managed database already
  exists and is shared with the read models — only the `eventstore` schema and
  its tables are provisioned. Idempotent.
  """
  def setup_event_store do
    load_app()
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ssl)

    for event_store <- Application.get_env(@app, :event_stores, []) do
      # Keep the setup's own connections minimal (it's connection-constrained too).
      config = Keyword.put(event_store.config(), :pool_size, 2)
      maybe_bootstrap_schema_as_admin(config)
      ensure_schema!(config)
      :ok = EventStore.Tasks.Init.exec(config, quiet: true)
    end

    :ok
  end

  # One-time bootstrap for a managed DB whose app user lacks CREATE on the database.
  # If DB_ADMIN_URL is set, connect with that admin's credentials (e.g. DO's
  # `doadmin`) **to the app's own database** and create the event-store schema
  # **owned by the app user** — so the app user (from DATABASE_URL) can then
  # create/use its tables without further grants, and you can remove DB_ADMIN_URL
  # afterward. `CREATE SCHEMA` acts on the *current* database, and a `doadmin`
  # connection string points at `defaultdb`, not the app DB — so we deliberately use
  # the app's database (from DATABASE_URL), overridable with DB_ADMIN_DATABASE.
  # Idempotent (CREATE SCHEMA IF NOT EXISTS); a no-op when DB_ADMIN_URL is unset.
  defp maybe_bootstrap_schema_as_admin(config) do
    case System.get_env("DB_ADMIN_URL") do
      nil ->
        :ok

      admin_url ->
        schema = Keyword.fetch!(config, :schema)
        # config() has already parsed the url into discrete opts.
        app_user = Keyword.fetch!(config, :username)
        database = System.get_env("DB_ADMIN_DATABASE") || Keyword.fetch!(config, :database)
        {:ok, conn} = Postgrex.start_link(admin_conn_opts(admin_url, database))

        try do
          Postgrex.query!(
            conn,
            ~s|CREATE SCHEMA IF NOT EXISTS "#{schema}" AUTHORIZATION "#{app_user}"|,
            []
          )

          Logger.info(
            "[migrate] ensured schema #{inspect(schema)} owned by #{inspect(app_user)} " <>
              "in database #{inspect(database)} via DB_ADMIN_URL"
          )
        after
          GenServer.stop(conn)
        end
    end
  end

  defp admin_conn_opts(admin_url, database) do
    uri = URI.parse(String.split(admin_url, "?") |> hd())
    [user, pass] = String.split(uri.userinfo || ":", ":", parts: 2)

    base = [
      hostname: uri.host,
      port: uri.port || 5432,
      username: URI.decode(user),
      password: URI.decode(pass),
      # The admin URL's own database (e.g. defaultdb) is irrelevant — the schema must
      # be created in the app's database.
      database: database
    ]

    # Match the app's SSL posture (managed DBs require it; DATABASE_SSL=false opts out).
    if System.get_env("DATABASE_SSL") == "false" do
      base
    else
      base ++ [ssl: true, ssl_opts: [verify: :verify_none]]
    end
  end

  # Retry the whole migration on transient DB failures — connection crunch
  # (managed DB at its slot cap during a rolling deploy) or a migration-lock
  # **deadlock** (another migrator, or a lock left by a crash-looped boot). All are
  # transient and migrations are idempotent, so a re-run after a partial failure is
  # safe. A non-transient error (e.g. a genuinely broken migration) is re-raised at
  # once so it isn't masked by pointless retries.
  defp with_retry(fun, attempt \\ 1) do
    fun.()
  rescue
    e ->
      if attempt < @max_attempts and retryable?(e) do
        wait = min(2_000 * Integer.pow(2, attempt - 1), 30_000)

        Logger.warning(
          "[migrate] #{Exception.message(e)} — attempt #{attempt}/#{@max_attempts}, " <>
            "retrying in #{wait}ms"
        )

        Process.sleep(wait)
        with_retry(fun, attempt + 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp retryable?(%DBConnection.ConnectionError{}), do: true
  defp retryable?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: true
  defp retryable?(%Postgrex.Error{postgres: %{code: :too_many_connections}}), do: true

  defp retryable?(e) do
    # Ecto sometimes wraps the lock deadlock / connection issues in a RuntimeError;
    # match on the message as a fallback.
    msg = Exception.message(e)

    String.contains?(msg, [
      "deadlock",
      "connection not available",
      "too many connections",
      "tcp closed",
      "timed out"
    ])
  end

  # Ensure the event-store schema exists. Check first (a SELECT the app user can
  # always do) and only CREATE if it's genuinely missing — because Postgres checks
  # the CREATE privilege *before* the "already exists" case, so an app user without
  # database-level CREATE gets `permission denied` even for an existing schema (e.g.
  # one made by the DB_ADMIN_URL bootstrap or pre-created by hand).
  defp ensure_schema!(config) do
    if schema_exists?(config) do
      :ok
    else
      create_schema!(config)
    end
  end

  defp schema_exists?(config) do
    conn_opts =
      Keyword.take(config, [:hostname, :port, :username, :password, :database, :ssl, :ssl_opts])

    {:ok, conn} = Postgrex.start_link(conn_opts)

    try do
      %{rows: [[exists?]]} =
        Postgrex.query!(
          conn,
          "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = $1)",
          [Keyword.fetch!(config, :schema)]
        )

      exists?
    after
      GenServer.stop(conn)
    end
  end

  defp create_schema!(config) do
    case EventStore.Storage.Schema.create(config) do
      :ok ->
        :ok

      {:error, :already_up} ->
        :ok

      {:error, reason} ->
        message = to_string(inspect(reason))

        if String.contains?(message, ["insufficient_privilege", "permission denied"]) do
          schema = Keyword.fetch!(config, :schema)

          raise """
          Could not create the event store schema #{inspect(schema)}: #{message}

          The app's database user lacks CREATE on the database. Easiest fix (no DB
          console needed): set the DB_ADMIN_URL env var to the admin connection
          string (DO's `doadmin`) and redeploy — the app will create the schema
          owned by the app user, then you can remove DB_ADMIN_URL.

          Or, from a DB console as the admin, run once then redeploy:

              CREATE SCHEMA IF NOT EXISTS #{schema} AUTHORIZATION "<app_user>";

          (<app_user> is the username in DATABASE_URL.) See docs/deployment.md.
          """
        else
          raise "failed to create event store schema: #{message}"
        end
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
