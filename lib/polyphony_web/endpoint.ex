defmodule PolyphonyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :polyphony

  # The session — signed cookie. Auth stores the current user id here (§B2 transport).
  @session_options [
    store: :cookie,
    key: "_polyphony_key",
    signing_salt: "pR6pHoNy",
    same_site: "Lax"
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
