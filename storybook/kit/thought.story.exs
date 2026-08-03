defmodule Storybook.Kit.Thought do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.thought/1

  def template do
    """
    <div class="fr stage dark sheet p-4">
      <div class="mb-3"><.psb-variation/></div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :wren,
        description:
          "A voice-coloured rule and a faint tint of the same hue — never italics. The note says who can see it, which is the visibility guarantee made legible: an interior move is structurally invisible to everyone else, not hidden behind a permission check.",
        attributes: %{colour: "var(--v1)", note: "Thought · only Wren"},
        slots: ["If he counts the crates, he'll know."]
      },
      %Variation{
        id: :ilias,
        description: "The same component in another voice — the hue is the character.",
        attributes: %{colour: "var(--v2)", note: "Thought · only Ilias"},
        slots: ["She has counted them twice and said nothing."]
      }
    ]
  end
end
