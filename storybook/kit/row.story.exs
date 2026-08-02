defmodule Storybook.Kit.Row do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.row/1

  def template do
    """
    <div class="fr stage dark sheet"><.psb-variation-group/></div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :rows,
        description:
          "A rule between items, not a box around each. Rows stay independent of their neighbours so windowing a long list later is a query change, not a markup change.",
        variations: [
          %Variation{
            id: :navigates,
            attributes: %{class: "px-4 py-2.5 flex items-center justify-between gap-2"},
            slots: [
              ~s|<span class="text-[13px] font-semibold">A row</span><span class="dim text-[14px]">›</span>|
            ]
          },
          %Variation{
            id: :carries_status,
            attributes: %{class: "px-4 py-2.5 flex items-center justify-between gap-2"},
            slots: [
              ~s|<span class="text-[13px] font-semibold">Another</span><span class="pill dim">status</span>|
            ]
          }
        ]
      }
    ]
  end
end
