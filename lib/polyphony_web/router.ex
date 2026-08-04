defmodule PolyphonyWeb.Router do
  use PolyphonyWeb, :router

  import PolyphonyWeb.Auth
  import PhoenixStorybook.Router
  import Phoenix.LiveDashboard.Router

  # Content-Security-Policy. `put_secure_browser_headers` sets the other headers but
  # never a CSP, and this app renders **other people's prose** — a published story is
  # authored by a stranger and read by anyone, which is the shape XSS likes.
  #
  # Each source list is as narrow as the app actually needs:
  #
  #   * `script-src 'self'` — the one script is `/assets/app.js`; nothing is inline, so
  #     no nonce and no `unsafe-inline`. This is the directive that matters.
  #   * `style-src` needs `'unsafe-inline'` for the kit's inline `style=` attributes
  #     (token colours computed per character), and Google Fonts' stylesheet.
  #   * `connect-src` names `ws:`/`wss:` explicitly rather than leaning on `'self'`,
  #     which not every browser reads as covering the LiveView socket.
  #   * `frame-ancestors 'none'` — clickjacking; `object-src 'none'` — legacy plugins.
  @csp """
  default-src 'self'; \
  script-src 'self'; \
  style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; \
  font-src 'self' data: https://fonts.gstatic.com; \
  img-src 'self' data:; \
  connect-src 'self' ws: wss:; \
  base-uri 'self'; \
  form-action 'self'; \
  frame-ancestors 'none'; \
  object-src 'none'\
  """

  # LiveDashboard ships inline `<script>` and `<style>`, which `script-src 'self'`
  # refuses — so the page loads and does nothing. Rather than weaken the policy for
  # everyone, this pipeline mints a per-request nonce, hands it to the dashboard
  # through assigns, and names it in a CSP that applies to this route only.
  pipeline :dashboard_csp do
    plug(:put_dashboard_nonce)
  end

  pipeline :mailbox do
    plug(:allow_mailbox)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PolyphonyWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers, %{"content-security-policy" => @csp})
    plug(:fetch_current_user)
  end

  # Public + authed-optional.
  scope "/", PolyphonyWeb do
    pipe_through(:browser)

    get("/logout", AuthController, :logout)

    # `session:` lifts the remember-me cookie into the LiveView session. It has to
    # happen here: `on_mount` hooks are handed the session rather than the conn, and
    # cookies aren't in `connect_info`, so this dead-render callback is the only place
    # with a conn to read one from.
    live_session :public,
      on_mount: [{PolyphonyWeb.Auth, :mount_current_user}],
      session: {PolyphonyWeb.Auth, :remembered_session, []} do
      live("/", HomeLive, :index)
      live("/login", LoginLive, :index)
      live("/signup", SignupLive, :index)
      live("/resume", ResumeLive, :index)
      live("/browse", BrowseLive, :index)
      live("/s/:token", ShareLive, :show)
    end
  end

  # Dev-only magic-link resolution (in prod this is an emailed URL).
  scope "/auth", PolyphonyWeb do
    pipe_through(:browser)
    get("/verify/:token", AuthController, :verify)
    get("/forget", AuthController, :forget)
  end

  # Requires a signed-in account.
  scope "/", PolyphonyWeb do
    pipe_through(:browser)

    # Same `session:` as `:public`, and this is the one that earns it: `require_authed`
    # reads the remembered id to decide between `/resume` and `/login`.
    live_session :authed,
      on_mount: [{PolyphonyWeb.Auth, :require_authed}],
      session: {PolyphonyWeb.Auth, :remembered_session, []} do
      live("/library", LibraryLive, :index)
      live("/settings", SettingsLive, :index)
      live("/campaigns/:id", CampaignLive, :show)
      live("/play/:scene_id", PlayLive, :show)
      live("/authoring/character/:id", SheetEditorLive, :edit)
      live("/authoring/bible/:id", BibleEditorLive, :edit)
      live("/authoring/group/:id", GroupEditorLive, :edit)
      live("/arc/:campaign_id", ArcReviewLive, :index)
    end
  end

  # Admin only.
  scope "/admin", PolyphonyWeb do
    pipe_through(:browser)

    live_session :admin, on_mount: [{PolyphonyWeb.Auth, :require_admin}] do
      live("/", AdminLive, :index)
    end
  end

  # Runtime introspection. **Admin-only, in every environment** — it lists processes,
  # reads ETS, and shows the environment, so it is a bigger exposure than anything else
  # the app serves. That is why it is gated on the role rather than on a build flag:
  # a flag protects a dev machine, `require_admin` protects the deployment.
  #
  # `allow_destructive_actions` stays off. The dashboard can kill processes, and there
  # is no version of that which is a good idea against a running scene.
  scope "/admin" do
    pipe_through([:browser, :dashboard_csp])

    live_dashboard("/dashboard",
      metrics: PolyphonyWeb.Telemetry,
      metrics_history: {PolyphonyWeb.Telemetry.History, :metrics_history, []},
      on_mount: [{PolyphonyWeb.Auth, :require_admin}],
      csp_nonce_assign_key: %{img: :img_nonce, style: :style_nonce, script: :script_nonce},
      allow_destructive_actions: false
    )
  end

  # The sent-mail viewer (Swoosh's Local adapter). It renders every message the app has
  # sent, **magic links included**, so `:mailbox` below decides per request whether it
  # exists at all: open in dev, HTTP Basic auth in prod, and 404 when neither is
  # configured.
  #
  # Gated at runtime rather than compiled out, because a release has to be able to
  # serve it when `MAILBOX_PASSWORD` is set — and a compile-time flag is fixed at image
  # build, long before anyone decides to turn it on.
  scope "/dev" do
    pipe_through([:browser, :mailbox])
    forward("/mailbox", Plug.Swoosh.MailboxPreview)
  end

  # The design-kit catalogue. Compiled in only where :storybook is on — dev by
  # default, elsewhere via STORYBOOK=true — so the routes don't exist at all in a
  # plain prod boot. It renders components and reads nothing from the domain,
  # which is why it needs no auth pipeline.
  if Application.compile_env(:polyphony, :storybook, false) do
    scope "/" do
      storybook_assets()
    end

    scope "/", PolyphonyWeb do
      pipe_through(:browser)
      live_storybook("/storybook", backend_module: PolyphonyWeb.Storybook)
    end
  end

  # Basic auth rather than `require_admin`, deliberately: the moment you need to read a
  # sign-in link is the moment you are not signed in, so an admin gate would lock the
  # door with the key inside. Unconfigured is a 404 — not a 401 — so an unarmed
  # deployment doesn't advertise that the viewer exists.
  defp allow_mailbox(conn, _opts) do
    cond do
      Application.get_env(:polyphony, :dev_mailbox, false) ->
        conn

      credentials = Application.get_env(:polyphony, :mailbox_auth) ->
        Plug.BasicAuth.basic_auth(conn, credentials)

      true ->
        conn |> Plug.Conn.send_resp(404, "Not found") |> Plug.Conn.halt()
    end
  end

  defp put_dashboard_nonce(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> Plug.Conn.assign(:script_nonce, nonce)
    |> Plug.Conn.assign(:style_nonce, nonce)
    |> Plug.Conn.assign(:img_nonce, nonce)
    |> Plug.Conn.put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self' 'nonce-#{nonce}'; " <>
        "style-src 'self' 'nonce-#{nonce}' 'unsafe-inline'; img-src 'self' data:; " <>
        "connect-src 'self' ws: wss:; base-uri 'self'; form-action 'self'; " <>
        "frame-ancestors 'none'; object-src 'none'"
    )
  end
end
