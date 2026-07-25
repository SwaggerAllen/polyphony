defmodule PolyphonyWeb.ErrorHTML do
  @moduledoc "Renders error pages as the plain status message (e.g. \"Not Found\")."
  use PolyphonyWeb, :html

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
