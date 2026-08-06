defmodule Storybook.Screens do
  use PhoenixStorybook.Index

  def folder_name, do: "Screens"
  def folder_open?, do: true

  @moduledoc """
  Whole composed screens, every state, rendered by the real components.

  This folder is the reason `STORYBOOK=true` in production: it is where a design
  session sees what the app actually looks like — including the states a live site
  would never happen to be in. Empty, failed, mid-generation, cap-hit, disconnected.
  """

  # Ordered the way somebody meets them: the way in, then the shelf, then the two
  # places the work happens, then the edges.
  def entry("login"), do: [name: "Sign in"]
end
