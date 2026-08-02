defmodule Storybook.Kit.Seg do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.seg/1

  def template do
    """
    <div class="fr stage dark p-4">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "A small closed set where the options are worth seeing at once.",
        slots: [
          ~s|<:option>Cheap</:option>|,
          ~s|<:option on>Balanced</:option>|,
          ~s|<:option>Best</:option>|
        ]
      }
    ]
  end
end
