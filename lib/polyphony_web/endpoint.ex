defmodule PolyphonyWeb.Endpoint do
  # Before `Phoenix.Endpoint`, and it has to be: it wraps the whole `call/2` so an error
  # raised anywhere below — including inside the router, before any of our own code runs
  # — is reported before Cowboy turns it into a 500 and forgets it. This is the Cowboy
  # recommendation specifically; on Bandit it would double-report, and this app runs
  # Cowboy (see `plug_cowboy` in mix.exs).
  #
  # No-op without a DSN. `Sentry.PlugContext` — the request's path, params and headers —
  # is in the router, where the pipelines are.
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :polyphony

  # The session — signed cookie. Auth stores the current user id here (§B2 transport).
  #
  # `max_age` is 30 days. It used to be absent, which does not mean "forever" — it makes
  # a *session cookie*, one the browser drops when it closes, and on a phone that is
  # whenever the OS decides. `Plug.Session.COOKIE` puts no separate expiry on the
  # signature (it verifies without a `max_age`), so this value is the whole lifetime:
  # after 30 days the cookie is gone and the next visit is a signed-out one.
  #
  # This is a real credential, unlike `_polyphony_remember` — it *is* being signed in,
  # where the remember cookie only offers to email you a link. So the two are not the
  # same kind of thing with different numbers on them, and the session must stay the
  # shorter of the two.
  @session_max_age 60 * 60 * 24 * 30

  @session_options [
    store: :cookie,
    key: "_polyphony_key",
    signing_salt: "pR6pHoNy",
    same_site: "Lax",
    max_age: @session_max_age
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Vendored, prebuilt assets — no bundler (see priv/static/assets).
  plug(Plug.Static,
    at: "/",
    from: :polyphony,
    gzip: false,
    only: PolyphonyWeb.static_paths()
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  # In test, let a Wallaby browser request check out the test's sandboxed DB
  # connection (via metadata in the user-agent). Compiled out everywhere else.
  if Application.compile_env(:polyphony, :sql_sandbox) do
    plug(Phoenix.Ecto.SQL.Sandbox)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(PolyphonyWeb.Router)
end
