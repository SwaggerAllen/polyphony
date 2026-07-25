import Config

# Production runtime configuration is supplied via config/runtime.exs (env vars).
# The persistent EventStore adapter should be enabled here once provisioned.

# Web endpoint in prod: served, cache static manifest, URL from env (see runtime.exs).
config :polyphony, PolyphonyWeb.Endpoint,
  url: [host: {:system, "PHX_HOST"}, port: 443, scheme: "https"],
  server: true
