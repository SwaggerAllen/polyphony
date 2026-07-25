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
      # These lower bounds were chosen for the original Elixir 1.14 toolchain and
      # still resolve cleanly on the modern one; left as-is to avoid churn.
      {:ecto_sql, "~> 3.11.0"},
      {:postgrex, "~> 0.17.5"},
      {:pgvector, "~> 0.3.0"},

      # Job dispatch (§2): Postgres-backed, retries, concurrency control.
      {:oban, "~> 2.17"},

      # Per-viewer client streaming (§13). Standalone PubSub — a LiveView (or a
      # push-notification worker) subscribes to the filtered per-viewer topics.
      {:phoenix_pubsub, "~> 2.1"},

      # Web layer (LiveView frontend). On the modern toolchain (OTP 27 / Elixir 1.17,
      # provided by the SessionStart hook) we run current Phoenix + LiveView. The
      # server is Cowboy (Phoenix 1.8 defaults to Bandit, but Cowboy is fully
      # supported and already wired here).
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:plug_cowboy, "~> 2.7"},
      {:lazy_html, ">= 0.1.0", only: :test},

      # NOTE: the DeepInfra adapter uses Erlang's built-in :httpc (see
      # Polyphony.LLM.DeepInfra) rather than Req — a zero-dependency choice made
      # under the old Elixir 1.14 toolchain. The provider behaviour keeps the HTTP
      # client swappable, so moving to ReqLLM on the modern toolchain later is a
      # one-module change.

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
