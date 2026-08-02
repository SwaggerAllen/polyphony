defmodule Storybook.Kit.Sw do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.sw/1

  def template do
    """
    <div class="fr stage dark p-4 flex items-center gap-4">
      <.psb-variation-group/>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :meanings,
        description:
          "One boolean pattern, same geometry everywhere, coloured by what it means. Label on the left, control right-aligned. Independent of each other: a fact can be secret and always in mind.",
        variations: [
          %Variation{
            id: :always_in_mind,
            attributes: %{on: true, colour: "var(--lamp)"}
          },
          %Variation{id: :secret, attributes: %{on: true, colour: "var(--secret)"}},
          %Variation{id: :off, attributes: %{on: false}}
        ]
      }
    ]
  end
end
