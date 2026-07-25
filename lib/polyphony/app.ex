defmodule Polyphony.App do
  @moduledoc """
  The Commanded application — the write-side boundary.

  Commands are dispatched here; the configured router (see `Polyphony.Router`)
  routes them to aggregates, which validate and emit events into the event
  store. Read-model projectors subscribe to that store separately.
  """
  use Commanded.Application,
    otp_app: :polyphony

  # Force Router to compile first: the `router/1` macro reads its registered
  # commands at compile time, and without an explicit compile-time dependency
  # the parallel compiler can order App ahead of Router.
  require Polyphony.Router

  router(Polyphony.Router)
end
