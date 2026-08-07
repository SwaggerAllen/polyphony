defmodule Storybook.Screens do
  use PhoenixStorybook.Index

  # The catalogue is a reviewing surface, not part of the app's layering — it renders
  # components and reaches nothing that reaches back.
  use Boundary, check: [in: false, out: false]

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
  def entry("home"), do: [name: "Landing"]
  def entry("login"), do: [name: "Sign in"]
  def entry("resume"), do: [name: "Resume"]
  def entry("share"), do: [name: "Shared link"]
  def entry("play"), do: [name: "Play"]
  def entry("signup"), do: [name: "Sign up"]
  def entry("settings"), do: [name: "Settings"]
  def entry("arc_review"), do: [name: "Arc review"]
  def entry("group_editor"), do: [name: "Group editor"]
  def entry("library"), do: [name: "Library"]
end
