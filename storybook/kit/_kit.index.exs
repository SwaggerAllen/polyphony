defmodule Storybook.Kit do
  use PhoenixStorybook.Index

  def folder_name, do: "Components"
  def folder_open?, do: true

  # Ordered the way the design catalogue is: the frame everything sits in, then
  # the idiom the product is built around, then controls, then the surfaces that
  # compose them.
  def entry("frame"), do: [name: "Frame & registers"]
  def entry("viewas"), do: [name: "Perspective control"]
  def entry("btn"), do: [name: "Buttons"]
  def entry("pill"), do: [name: "Pills"]
  def entry("dot"), do: [name: "Dots"]
  def entry("sw"), do: [name: "Switch"]
  def entry("chk"), do: [name: "Checks"]
  def entry("seg"), do: [name: "Segmented control"]
  def entry("bar"), do: [name: "Progress bar"]
  def entry("info"), do: [name: "Info affordance"]
  def entry("sheet"), do: [name: "Sheets"]
  def entry("row"), do: [name: "Rows"]
  def entry("tabs"), do: [name: "Tabs"]
  def entry("jump"), do: [name: "Jump bar & scrubber"]
  def entry("beat_rule"), do: [name: "Beat rule"]
  def entry("world_move"), do: [name: "Director narration"]
  def entry("thought"), do: [name: "Interior monologue"]
  def entry("fail_move"), do: [name: "Failed generation"]
  def entry("strip"), do: [name: "Status strip"]
  def entry("marked"), do: [name: "Marked list items"]
  def entry("chip_core"), do: [name: "Always-in-mind chip"]
  def entry("empty"), do: [name: "Empty state"]
  def entry("skel"), do: [name: "Skeleton"]
end
