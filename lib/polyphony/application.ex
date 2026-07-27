defmodule Polyphony.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    maybe_migrate_on_boot()
    maybe_reset_bootstrap()

    children =
      [
        Polyphony.Repo,
        Polyphony.Context.Store,
        {Phoenix.PubSub, name: Polyphony.PubSub},
        {Oban, Application.fetch_env!(:polyphony, Oban)},
        Polyphony.App,
        Polyphony.Broadcast.Publisher,
        PolyphonyWeb.Telemetry,
        PolyphonyWeb.Endpoint
      ] ++ debug_log() ++ projectors() ++ shutdown_hook()

    opts = [strategy: :one_for_one, name: Polyphony.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Last child ⇒ terminates first on shutdown, releasing DB connections early so a
  # rolling deploy's outgoing instance frees its slots before the new one boots.
  # Off in test (would touch the SQL sandbox).
  defp shutdown_hook do
    if Application.get_env(:polyphony, :drain_on_shutdown, true) do
      [Polyphony.ShutdownHook]
    else
      []
    end
  end

  # Run migrations + event-store setup before the app serves, when enabled
  # (prod). This makes the schema self-healing on every boot, so a deploy can't
  # come up with missing tables even if the pre-deploy migrate job didn't run.
  # Idempotent, and Ecto's migration lock makes it safe across instances. Off by
  # default (dev/test drive their own schema).
  defp maybe_migrate_on_boot do
    if Application.get_env(:polyphony, :migrate_on_boot, false) do
      Logger.info("[boot] running migrations + event-store setup")
      Polyphony.Release.migrate()
      Logger.info("[boot] migrations complete")
    end
  end

  # One-shot cleanup of a failed sign-up bootstrap (RESET_INCOMPLETE_BOOTSTRAP).
  # Deletes leftover partial users *only* when no account has completed sign-up, so
  # the first sign-up can bootstrap the superadmin cleanly. Set the env for one
  # deploy, then remove it. Off by default.
  defp maybe_reset_bootstrap do
    if Application.get_env(:polyphony, :reset_incomplete_bootstrap, false) do
      Logger.info("[boot] checking sign-up bootstrap state")
      Polyphony.Release.clean_incomplete_bootstrap()
    end
  end

  # The debug-log ring buffer + :logger handler backing PolyphonyWeb.DebugDrawerLive.
  # Only started when the drawer is enabled (DEBUG_DRAWER in prod); depends on PubSub
  # (already started above) for broadcasting captured lines to connected drawers.
  defp debug_log do
    if Application.get_env(:polyphony, :debug_drawer, false) do
      [Polyphony.DebugLog]
    else
      []
    end
  end

  # Ecto projectors run as their own processes subscribed to the event store. In
  # tests we drive the read model's SQL directly (see the membership read-model
  # test), so the live projector is left out there to avoid coupling every
  # Commanded dispatch to the Ecto sandbox.
  defp projectors do
    if Application.get_env(:polyphony, :start_projectors, true) do
      [Polyphony.Projectors.SceneMemberships, Polyphony.Projectors.SceneForks]
    else
      []
    end
  end
end
