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
        Polyphony.DebugTap,
        {Oban, Application.fetch_env!(:polyphony, Oban)},
        Polyphony.App,
        Polyphony.Broadcast.Publisher,
        PolyphonyWeb.Telemetry,
        PolyphonyWeb.Endpoint
      ] ++ debug_log() ++ projectors() ++ shutdown_hook()

    opts = [strategy: :one_for_one, name: Polyphony.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # After the tree is up (so the debug-drawer log handler is attached and can
        # capture this line too, not just the console).
        log_web_origin_config()
        {:ok, pid}

      other ->
        other
    end
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

  # Surface the endpoint host + origin-check config at boot. If the LiveView socket
  # is being rejected ("Could not check origin …"), this line shows whether PHX_HOST
  # resolved to the real domain and what check_origin the socket will enforce — the
  # first thing to look at (visible in the debug drawer). Cheap, so always logged.
  defp log_web_origin_config do
    cfg = Application.get_env(:polyphony, PolyphonyWeb.Endpoint, [])
    host = cfg |> Keyword.get(:url, []) |> Keyword.get(:host)

    Logger.info(
      "[boot] endpoint host=#{inspect(host)} check_origin=#{inspect(cfg[:check_origin])}"
    )
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

  # Event-store subscription processes whose read-side work touches Postgres: the
  # Ecto projectors, and the scene-close fan-out handler (it enqueues Oban jobs via
  # `Oban.insert!`). In tests we drive the read model's SQL and `SceneClose.run/2`
  # directly, so these are left out there to keep Commanded dispatch off the Ecto
  # sandbox — the flag is `start_projectors` for both. (`Broadcast.Publisher`
  # subscribes too but needs no Postgres, so it runs unconditionally above.)
  defp projectors do
    if Application.get_env(:polyphony, :start_projectors, true) do
      [
        Polyphony.Projectors.SceneMemberships,
        Polyphony.Projectors.SceneForks,
        Polyphony.SceneClose.Handler
      ]
    else
      []
    end
  end
end
