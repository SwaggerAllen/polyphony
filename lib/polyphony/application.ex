defmodule Polyphony.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Polyphony.Repo,
      Polyphony.App,
      Polyphony.Projectors.SceneMemberships
    ]

    opts = [strategy: :one_for_one, name: Polyphony.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
