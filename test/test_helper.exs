ExUnit.start()

# DB-backed tests use the SQL sandbox; pure tests (visibility, membership set,
# aggregate) touch neither the Repo nor the Commanded runtime.
Ecto.Adapters.SQL.Sandbox.mode(Polyphony.Repo, :manual)
