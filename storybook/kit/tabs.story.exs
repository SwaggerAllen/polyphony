defmodule Storybook.Kit.Tabs do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.tabs/1

  def template do
    """
    <div class="fr stage dark sheet">
      <.psb-variation/>
      <div class="px-4 py-4">
        <p class="text-[12.5px] leading-relaxed dim">Sectioned screens — campaign, library, browse, admin. Scrolls horizontally and never wraps.</p>
      </div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :campaign,
        description:
          "The amber dot means unbuilt, and is only used on a campaign's first run — it's an invitation, not an error.",
        slots: [
          ~s|<:tab on patch="#">Settings</:tab>|,
          ~s|<:tab todo patch="#">World</:tab>|,
          ~s|<:tab todo patch="#">Cast</:tab>|,
          ~s|<:tab patch="#">Groups</:tab>|,
          ~s|<:tab patch="#">Premise</:tab>|,
          ~s|<:tab patch="#">Scenes</:tab>|
        ]
      }
    ]
  end
end
