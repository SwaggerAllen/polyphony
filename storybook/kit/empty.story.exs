defmodule Storybook.Kit.Empty do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.empty/1

  def template do
    """
    <div class="fr stage dark sheet mb-3"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :nobody_yet,
        description:
          "A Spectral headline in the fiction's voice, a plain line of explanation, one action. Never \"No items found.\"",
        attributes: %{headline: "Nobody is on the quay yet."},
        slots: [
          "Pick who's in the room and the Director will open the scene.",
          ~s|<:action><button class="btn btn-pri btn-sm">Open the scene</button></:action>|
        ]
      },
      %Variation{
        id: :headline_only,
        description: "The explanation and the action are both optional; the voice isn't.",
        attributes: %{headline: "No one has written here yet."}
      }
    ]
  end
end
