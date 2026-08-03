defmodule PolyphonyWeb.Router do
  use PolyphonyWeb, :router

  import PolyphonyWeb.Auth
  import PhoenixStorybook.Router

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

    live_session :public, on_mount: [{PolyphonyWeb.Auth, :mount_current_user}] do
      live("/", HomeLive, :index)
      live("/login", LoginLive, :index)
      live("/signup", SignupLive, :index)
      live("/browse", BrowseLive, :index)
      live("/s/:token", ShareLive, :show)
    end
  end

  # Dev-only magic-link resolution (in prod this is an emailed URL).
  scope "/auth", PolyphonyWeb do
    pipe_through(:browser)
    get("/verify/:token", AuthController, :verify)
  end

  # Requires a signed-in account.
  scope "/", PolyphonyWeb do
    pipe_through(:browser)

    live_session :authed, on_mount: [{PolyphonyWeb.Auth, :require_authed}] do
      live("/library", LibraryLive, :index)
      live("/settings", SettingsLive, :index)
      live("/campaigns/:id", CampaignLive, :show)
      live("/play/:scene_id", PlayLive, :show)
      live("/authoring/character/:id", SheetEditorLive, :edit)
      live("/authoring/bible/:id", BibleEditorLive, :edit)
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
end
