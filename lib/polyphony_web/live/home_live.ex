defmodule PolyphonyWeb.HomeLive do
  @moduledoc """
  The landing page: what this is, and the way in.

  It is the only screen a stranger sees before deciding whether to make an account, and
  the thing it has to get across is not a feature list — it's that the characters here
  **don't know what you know**. Everything else (world bibles, arcs, forks) is ordinary
  writing-tool furniture and explains itself once you're inside; the filtered projection
  is the reason to be here at all and is invisible in a screenshot.

  So the middle of the page is a transcript, not a paragraph about transcripts. It uses
  the kit's own transcript components — `Kit.thought/1` with its attribution line, which
  is the visibility guarantee made legible — so what a stranger reads on the landing page
  is the same thing they will read in play, drawn by the same code.

  Signed in, the pitch collapses and the page is a way back to `/library` — nobody needs
  to be sold the product they are already using.
  """
  use PolyphonyWeb, :live_view

  alias PolyphonyWeb.Screens

  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Polyphony")}

  def render(assigns) do
    ~H"""
    <Screens.Home.screen
      current_user={@current_user}
    />
    """
  end
end
