defmodule PolyphonyWeb do
  @moduledoc """
  The web layer entrypoint: `use PolyphonyWeb, :controller` / `:live_view` / `:html`
  / `:router` pull in the shared imports. Kept lean and hand-written (no generators).
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html],
        layouts: [html: PolyphonyWeb.Layouts]

      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {PolyphonyWeb.Layouts, :app}
      import PolyphonyWeb.SafeEvent, only: [safe: 2]
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import PolyphonyWeb.CoreComponents
      alias Phoenix.LiveView.JS
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: PolyphonyWeb.Endpoint,
        router: PolyphonyWeb.Router,
        statics: PolyphonyWeb.static_paths()
    end
  end

  @doc "Dispatch `use PolyphonyWeb, :thing` to the matching macro above."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
