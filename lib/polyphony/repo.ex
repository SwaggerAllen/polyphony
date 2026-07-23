defmodule Polyphony.Repo do
  @moduledoc """
  Read-model repository (Postgres + pgvector).

  This holds *projections* over the event log — never the source of truth. The
  event log lives in the Commanded event store. Everything here is rebuildable
  by replaying events, per the foundational rule that knowledge is a projection.
  """
  use Ecto.Repo,
    otp_app: :polyphony,
    adapter: Ecto.Adapters.Postgres
end
