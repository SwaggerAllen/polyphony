defmodule Storybook.Root do
  use PhoenixStorybook.Index

  # The catalogue is a reviewing surface, not part of the app's layering — it renders
  # components and reaches nothing that reaches back.
  use Boundary, check: [in: false, out: false]

  def folder_icon, do: {:fa, "book-open", :light, "psb-mr-1"}
  def folder_name, do: "The kit"

  def entry("welcome"), do: [name: "Read this first", icon: {:fa, "hand", :thin}]
end
