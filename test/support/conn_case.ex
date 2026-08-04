defmodule PolyphonyWeb.ConnCase do
  @moduledoc """
  Test case for connection/LiveView tests. Sets up a request `conn`, the SQL sandbox
  in shared mode (so the LiveView process shares the test's DB connection), and login
  helpers.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use PolyphonyWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PolyphonyWeb.ConnCase

      @endpoint PolyphonyWeb.Endpoint
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Polyphony.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Polyphony.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Run the enqueued authoring generations and re-render.

  The ✦ controls used to be `start_async`, so tests waited with `render_async/1`. They
  are Oban jobs now (`Polyphony.Jobs.Generate`) because a provider call that takes
  seconds must not die with the tab — so the wait becomes a drain, and the separation is
  the point: pressing the button and getting the answer are no longer one act.
  """
  def generate(view) do
    Oban.drain_queue(queue: :generation)
    Phoenix.LiveViewTest.render(view)
  end

  @doc "Insert a user directly (bypassing the sign-up gates), returning the struct."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "u#{n}@x.io",
      username: "user#{n}",
      role: "user",
      attested_adult_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    }

    {:ok, user} =
      defaults
      |> Map.merge(Map.new(attrs))
      |> Polyphony.Accounts.User.registration_changeset()
      |> Polyphony.Repo.insert()

    user
  end

  @doc "Put `user` in the session so the conn is authenticated."
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  @doc "Create a user and log them in; returns `%{conn:, user:}`."
  def register_and_log_in_user(%{conn: conn} = _context, attrs \\ %{}) do
    user = user_fixture(attrs)
    %{conn: log_in_user(conn, user), user: user}
  end
end
