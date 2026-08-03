defmodule Storybook.Kit.WaitingLine do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.waiting_line/1

  def template do
    """
    <div class="fr stage dark sheet p-4"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :director,
        description:
          "Lamp, because the kit reserves that colour for *now*. A sentence rather than a spinner — it can say what is being waited on.",
        attributes: %{label: "The director is setting the scene…"}
      },
      %Variation{
        id: :a_character,
        attributes: %{label: "Wren Ashgrove is writing their turn…"}
      }
    ]
  end
end
