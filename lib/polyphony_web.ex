defmodule PolyphonyWeb do
  # The web layer may call the domain; the domain may not call back — that direction is
  # a compile error, and `Polyphony`'s own declaration explains why `exports: :all` is
  # still the loose half of this.
  #
  # **The export list is what constrains `PolyphonyWeb.Screens`**, which is a sub-boundary
  # and therefore reaches this one only through its exports. Everything listed is
  # presentation: components and pure formatting. Everything not listed — `Auth`, `Guard`,
  # `SafeEvent`, `Endpoint`, `Telemetry`, every LiveView — is out of a screen's reach, and
  # naming one is a compile error rather than a review comment.
  #
  # LiveViews and controllers are *inside* this boundary, so none of this constrains them;
  # they call whatever they need. The list exists for the one sub-boundary.
  use Boundary,
    deps: [Polyphony],
    exports: [AudiencePicker, BlockField, Kit, Layouts, Transcript, TurnEdit, Voice]

  @moduledoc """
  The web layer entrypoint: `use PolyphonyWeb, :controller` / `:live_view` / `:html`
  / `:router` pull in the shared imports. Kept lean and hand-written (no generators).
  """

  # `docs` and `ux` are the design and architecture docs, copied under `priv/static` by
  # `mix docs.publish` so a release carries them and the app serves them. Public and
  # deliberately so — see that task.
  def static_paths, do: ~w(assets docs ux favicon.ico robots.txt)

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
