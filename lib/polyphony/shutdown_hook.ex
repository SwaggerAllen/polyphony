defmodule Polyphony.ShutdownHook do
  @moduledoc """
  Releases database connections **early** when the app shuts down.

  On a clean OTP shutdown the Repo/EventStore pools already close their
  connections when they terminate — and a clean client `Terminate` frees the
  Postgres backend immediately, whereas a *killed* connection lingers until the
  server reaps the dead TCP socket (which can take minutes). The problem on a
  connection-capped managed DB is timing: during a rolling deploy the outgoing
  instance is still holding its slots while the incoming one boots, so the new
  instance can hit `too many connections` / `no connection available`.

  This process is placed **last** in the supervision tree, so on shutdown it
  terminates **first** — before the in-flight work drains — and proactively
  disconnects the Repo pool then. That releases the slots at the very start of the
  shutdown window instead of the end, giving the incoming instance room.

  Best-effort: a hard SIGKILL or a crash can't run cleanup in-process, so those
  still linger until the server reaps them. Disabled in the test env (see
  `config/test.exs`) so it never touches the SQL sandbox.
  """
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, :ok}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("[shutdown] releasing database connections")
    disconnect(Polyphony.Repo)
    :ok
  end

  defp disconnect(repo) do
    if Process.whereis(repo), do: Ecto.Adapters.SQL.disconnect_all(repo, 0)
  rescue
    e -> Logger.warning("[shutdown] connection release failed: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end
end
