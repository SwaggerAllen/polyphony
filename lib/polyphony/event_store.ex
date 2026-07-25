defmodule Polyphony.EventStore do
  @moduledoc """
  Persistent event store for production.

  The event log is Polyphony's single source of truth, so a real deployment must
  persist it. In prod, `Polyphony.App` dispatches through the Commanded EventStore
  adapter, which stores every event in Postgres via this module. In dev and test
  the app uses Commanded's in-memory adapter instead (so the domain runs offline
  and the suite needs no event-store schema), and this module is simply never
  started — see `config/config.exs`.

  Its tables live in a dedicated `eventstore` schema in the same managed Postgres
  cluster as the read models (which stay in `public`), so one database backs both.
  Connection and schema come from `config/prod.exs` + `config/runtime.exs`; the
  schema/tables are created at deploy time by `Polyphony.Release.migrate/0`.
  """
  use EventStore, otp_app: :polyphony
end
