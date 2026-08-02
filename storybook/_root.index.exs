defmodule Storybook.Root do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "book-open", :light, "psb-mr-1"}
  def folder_name, do: "The kit"

  def entry("welcome"), do: [name: "Read this first", icon: {:fa, "hand", :thin}]
end
