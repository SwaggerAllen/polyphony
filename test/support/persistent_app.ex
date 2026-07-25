defmodule Polyphony.PersistentApp do
  @moduledoc """
  Test-only Commanded application bound to the **persistent** EventStore adapter —
  the production event-store path. Its store connection and schema are configured
  at runtime by `Polyphony.PersistentEventStoreTest`; it shares the real
  `Polyphony.Router`, so commands route to the same aggregates as `Polyphony.App`.

  The rest of the suite runs on the in-memory adapter (fast, sandbox-isolated);
  this app exists only so one test can prove dispatch → persist → replay against
  Postgres, catching prod-config drift the in-memory suite can't see.
  """
  use Commanded.Application, otp_app: :polyphony

  require Polyphony.Router
  router(Polyphony.Router)
end
