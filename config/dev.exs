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
    tailwind: {Tailwind, :install_and_run, [:polyphony, ~w(--watch)]},
    storybook_tailwind: {Tailwind, :install_and_run, [:storybook, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/polyphony_web/.*(ex|heex)$",
      ~r"storybook/.*\.exs$"
    ]
  ]

# The debug drawer is handy while developing — stream server logs into the page.
config :polyphony, :debug_drawer, true

# The component catalogue at /storybook — always on in dev, where the kit is
# being ported and every component wants looking at in isolation.
config :polyphony, :storybook, true

# Mail locally, without a provider. Swoosh's Local adapter keeps messages in memory
# and `/dev/mailbox` renders them, which is the only way to see the *actual* email —
# subject, body, and the provider headers — rather than the link the login screen
# already prints. Dev only: the route and the storage process are both gated on this.
config :polyphony, :dev_mailbox, true
config :polyphony, Polyphony.Mailer, adapter: Swoosh.Adapters.Local
config :polyphony, :mail_from, "polyphony@localhost"

# Point the notification path at the real transport, or nothing reaches Swoosh at all
# and the mailbox stays empty — `Transport.Log` would happily report success.
config :polyphony, :notification_transport, Polyphony.Notifications.Transport.Email

config :logger, :console, level: :info
