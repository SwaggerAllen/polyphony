Postgrex.Types.define(
  Polyphony.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
