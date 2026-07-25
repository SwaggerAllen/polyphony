defmodule Polyphony.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
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
