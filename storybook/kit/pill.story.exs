defmodule Storybook.Kit.Pill do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.pill/1

  def template do
    """
    <div class="fr stage dark p-4">
      <.psb-variation-group/>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :status,
        description:
          "Status, never an action: if it does something on tap it's a button. Colour by meaning — lamp is now, ok is done, pencil is wrong, secret is concealed.",
        variations: [
          %Variation{id: :neutral, slots: ["Neutral"]},
          %Variation{id: :now, attributes: %{colour: "var(--lamp)"}, slots: ["Now"]},
          %Variation{id: :done, attributes: %{colour: "var(--ok)"}, slots: ["Done"]},
          %Variation{id: :wrong, attributes: %{colour: "var(--pencil)"}, slots: ["Wrong"]},
          %Variation{id: :secret, attributes: %{colour: "var(--secret)"}, slots: ["Secret"]}
        ]
      }
    ]
  end
end
