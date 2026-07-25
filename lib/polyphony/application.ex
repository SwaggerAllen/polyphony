defmodule Polyphony.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    maybe_migrate_on_boot()

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
      ] ++ projectors()

    opts = [strategy: :one_for_one, name: Polyphony.Supervisor]
    Supervisor.start_link(children, opts)
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
