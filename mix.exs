defmodule Polyphony.MixProject do
  use Mix.Project

  def project do
    [
      app: :polyphony,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Polyphony.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Event sourcing / CQRS
      {:commanded, "~> 1.4"},
      {:commanded_ecto_projections, "~> 1.4"},

      # Persistence for read models (pgvector for scene/summary embeddings later).
      # Versions pinned for Elixir 1.14 (the distro toolchain); newer postgrex
      # requires 1.15+.
      {:ecto_sql, "~> 3.11.0"},
      {:postgrex, "~> 0.17.5"},
      {:pgvector, "~> 0.3.0"},

      # Job dispatch (§2): Postgres-backed, retries, concurrency control.
      {:oban, "~> 2.17"},

      # NOTE: the DeepInfra adapter uses Erlang's built-in :httpc (see
      # Polyphony.LLM.DeepInfra) rather than Req. On this Elixir 1.14 toolchain
      # Req's HTTP/2 stack (finch/mint/hpax) forces packages that require 1.15+
      # and carry their own advisories. The provider behaviour keeps the HTTP
      # client swappable, so moving to ReqLLM later is a one-module change.

      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      # Set up the read-model database from scratch.
      setup: ["deps.get", "ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
