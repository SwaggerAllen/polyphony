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

      # Per-viewer client streaming (§13). Standalone PubSub — a LiveView (or a
      # push-notification worker) subscribes to the filtered per-viewer topics.
      {:phoenix_pubsub, "~> 2.1"},

      # Web layer (LiveView frontend). Phoenix 1.7 / LiveView 0.20 are the last
      # lines supporting the Elixir 1.14 toolchain (1.8 needs 1.15+). The server is
      # Cowboy, not Bandit: Bandit's HTTP/2 stack pulls `hpax`, which requires Elixir
      # 1.15+ and fails to compile here (the same 1.15 wall the README notes for Req).
      # Assets are vendored (no esbuild/tailwind binary download) — see
      # priv/static/assets and the root layout.
      {:phoenix, "~> 1.7.14"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 0.20.17"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:plug_cowboy, "~> 2.7"},
      # Pin Plug to the last line supporting Elixir 1.14 — 1.19+ requires 1.15+.
      {:plug, "~> 1.16.1", override: true},
      # LiveView test DOM parsing. Pinned to a line that supports Elixir 1.14
      # (0.37+ requires 1.15+).
      {:floki, "~> 0.36.0", only: :test},

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
