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
      ensure_schema!(config)
      :ok = EventStore.Tasks.Init.exec(config, quiet: true)
    end

    :ok
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

  # CREATE SCHEMA "eventstore" over the existing DATABASE_URL connection; a schema
  # that already exists is fine.
  defp ensure_schema!(config) do
    case EventStore.Storage.Schema.create(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "failed to create event store schema: #{inspect(reason)}"
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
