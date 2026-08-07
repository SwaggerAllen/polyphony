defmodule Storybook.Kit do
  use PhoenixStorybook.Index

  # The catalogue is a reviewing surface, not part of the app's layering — it renders
  # components and reaches nothing that reaches back.
  use Boundary, check: [in: false, out: false]

  def folder_name, do: "Components"
  def folder_open?, do: true

  # Ordered the way the design catalogue is: the frame everything sits in, then
  # the idiom the product is built around, then controls, then the surfaces that
  # compose them.
  def entry("frame"), do: [name: "Frame & registers"]
  def entry("header"), do: [name: "Screen header"]
  def entry("menu"), do: [name: "Overflow menu"]
  def entry("viewas"), do: [name: "Perspective control"]
  def entry("btn"), do: [name: "Buttons"]
  def entry("pill"), do: [name: "Pills"]
  def entry("dot"), do: [name: "Dots"]
  def entry("sw"), do: [name: "Switch"]
  def entry("chk"), do: [name: "Checks"]
  def entry("seg"), do: [name: "Segmented control"]
  def entry("bar"), do: [name: "Progress bar"]
  def entry("waiting_line"), do: [name: "Waiting line"]
  def entry("info"), do: [name: "Info affordance"]
  def entry("sheet"), do: [name: "Sheets"]
  def entry("row"), do: [name: "Rows"]
  def entry("overlay"), do: [name: "Overlay"]
  def entry("tabs"), do: [name: "Tabs"]
  def entry("jump"), do: [name: "Jump bar & scrubber"]
  def entry("beat_rule"), do: [name: "Beat rule"]
  def entry("world_move"), do: [name: "Director narration"]
  def entry("thought"), do: [name: "Interior monologue"]
  def entry("fail_move"), do: [name: "Failed generation"]
  def entry("strip"), do: [name: "Status strip"]
  def entry("marked"), do: [name: "Marked list items"]
  def entry("chip_core"), do: [name: "Always-in-mind chip"]
  def entry("audience"), do: [name: "Audience picker"]
  def entry("toast"), do: [name: "Toasts"]
  def entry("empty"), do: [name: "Empty state"]
  def entry("skel"), do: [name: "Skeleton"]
end
