import Config

# Production runtime configuration (secrets, DB URLs) is supplied via
# config/runtime.exs from env vars. This file holds the compile-time prod bits.

# Web endpoint in prod: served, cache the digested-asset manifest, URL from env
# (see runtime.exs).
config :polyphony, PolyphonyWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

# Persistent event store (prod only — see config/config.exs for the adapter
# switch). Static settings live here; the connection URL is injected at boot in
# config/runtime.exs. Events are serialized as JSONB and kept in a dedicated
# `eventstore` schema so the read models (public schema) share the same database.
config :polyphony, Polyphony.EventStore,
  serializer: Commanded.Serialization.JsonSerializer,
  column_data_type: "jsonb",
  schema: "eventstore"

# The event stores this app owns — read by `Polyphony.Release` when it creates
# the schema/tables at deploy time.
config :polyphony, event_stores: [Polyphony.EventStore]

config :logger, level: :info
