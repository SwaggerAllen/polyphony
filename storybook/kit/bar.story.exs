defmodule Storybook.Kit.Bar do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.bar/1

  def template do
    """
    <div class="fr stage dark p-4">
      <div class="mb-3"><.psb-variation/></div>
    </div>
    """
  end

  def variations do
    [
      %Variation{id: :empty, attributes: %{fraction: 0.0}},
      %Variation{id: :part_way, attributes: %{fraction: 0.62}},
      %Variation{id: :full, attributes: %{fraction: 1.0}},
      %Variation{
        id: :spent,
        description:
          "A ceiling reached means something different from progress toward one, so the colour changes to say so — the settings screen's spent state.",
        attributes: %{fraction: 1.0, colour: "var(--pencil)"}
      },
      %Variation{
        id: :out_of_range,
        description: "Clamped rather than overflowing its track — a bad count never draws wrong.",
        attributes: %{fraction: 1.8}
      }
    ]
  end
end
