import Config

config :polyphony, Polyphony.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "polyphony_dev",
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Offline by default in dev: the lorem-ipsum Mock provider so the full loop runs
# without network. Set provider: Polyphony.LLM.DeepInfra (+ DEEPINFRA_API_KEY) to
# hit the real model.
config :polyphony, :llm, provider: Polyphony.LLM.Mock

config :polyphony, PolyphonyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:polyphony, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:polyphony, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/polyphony_web/.*(ex|heex)$"
    ]
  ]

# The debug drawer is handy while developing — stream server logs into the page.
config :polyphony, :debug_drawer, true

config :logger, :console, level: :info
