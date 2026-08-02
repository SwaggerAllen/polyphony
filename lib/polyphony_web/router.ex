defmodule PolyphonyWeb.Router do
  use PolyphonyWeb, :router

  import PolyphonyWeb.Auth
  import PhoenixStorybook.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PolyphonyWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
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
