defmodule Polyphony.Release do
  @moduledoc """
  Release tasks — run at deploy time, before the app boots, from the built
  release (no Mix available in production).

  `migrate/0` is the deploy entrypoint: it runs the read-model Ecto migrations
  and then creates/updates the persistent event store's schema and tables. Both
  steps are idempotent, so it is safe to run on every deploy.

  Invoke from the release, e.g.:

      bin/polyphony eval "Polyphony.Release.migrate()"

  See `docs/deployment.md`.
  """
  @app :polyphony

  @doc "Run read-model migrations, then create/upgrade the event store schema."
  def migrate do
    load_app()
    migrate_read_models()
    setup_event_store()
    :ok
  end

  @doc "Run pending Ecto migrations for every read-model repo."
  def migrate_read_models do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
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
      config = event_store.config()
      ensure_schema!(config)
      :ok = EventStore.Tasks.Init.exec(config, quiet: true)
    end

    :ok
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
