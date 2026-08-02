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
      deps: deps(),
      releases: releases()
    ]
  end

  # Production release (built by the Dockerfile). `bin/polyphony start` boots the
  # app; `bin/polyphony eval "Polyphony.Release.migrate()"` runs migrations +
  # event-store setup before deploy (see docs/deployment.md).
  defp releases do
    [
      polyphony: [
        version: "0.1.0",
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
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
      # Persistent event store adapter — used in prod only (dev/test run on
      # Commanded's in-memory adapter). Pulls the `eventstore` library, which
      # keeps its tables in a dedicated Postgres schema (see config/prod.exs).
      {:commanded_eventstore_adapter, "~> 1.4"},

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
      {:phoenix_ecto, "~> 4.5"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # Component catalogue for the design kit (PolyphonyWeb.Kit). Renders each
      # component and its states on its own page so they can be reviewed without
      # hunting through screens — the guard against the kit and the shipped UI
      # drifting apart. Mounted at /storybook, gated by :storybook config
      # (dev-only by default; see config/config.exs).
      {:phoenix_storybook, "~> 1.3"},
      # Real-browser end-to-end tests (tagged :feature, excluded by default) —
      # drives Chromium over a live LiveSocket. See test/polyphony_web/features.
      {:wallaby, "~> 0.30", runtime: false, only: :test},

      # Asset pipeline: esbuild bundles assets/js/app.js (importing the phoenix /
      # phoenix_live_view JS shipped in deps), Tailwind builds assets/css/app.css.
      # Both are standalone binaries fetched by `mix assets.setup` — no Node.js.
      # The built outputs (priv/static/assets/app.{js,css}) are committed so the
      # app compiles and serves offline with no mandatory build step.
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},

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
      # Set up the read-model database and asset tooling from scratch.
      setup: ["deps.get", "assets.setup", "ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],

      # Asset tasks. `assets.setup` fetches the esbuild/tailwind binaries;
      # `assets.build` produces the dev bundles; `assets.deploy` is the minified
      # + digested prod build.
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      # `esbuild polyphony` emits app.js and storybook.js from one profile;
      # Tailwind needs a profile per entry point.
      "assets.build": ["tailwind polyphony", "tailwind storybook", "esbuild polyphony"],
      "assets.deploy": [
        "tailwind polyphony --minify",
        "tailwind storybook --minify",
        "esbuild polyphony --minify",
        "phx.digest"
      ]
    ]
  end
end
