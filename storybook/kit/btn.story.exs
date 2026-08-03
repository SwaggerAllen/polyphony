defmodule Storybook.Kit.Btn do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.btn/1

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
        id: :kinds,
        description:
          "Pencil is the editorial layer — reroll, edit, delete, branch — and is never a primary action. Unavailable is a look, not a disabled attribute: it still says why on tap.",
        variations: [
          %Variation{id: :primary, attributes: %{kind: :primary}, slots: ["Open the scene"]},
          %Variation{id: :ghost, attributes: %{kind: :ghost}, slots: ["Cancel"]},
          %Variation{id: :pen, attributes: %{kind: :pen}, slots: ["Reroll"]},
          %Variation{id: :red, attributes: %{kind: :red}, slots: ["Delete for good"]},
          %Variation{id: :off, attributes: %{kind: :off}, slots: ["Not yet"]}
        ]
      },
      %VariationGroup{
        id: :sizes,
        variations: [
          %Variation{id: :md, attributes: %{kind: :primary}, slots: ["Default"]},
          %Variation{id: :sm, attributes: %{kind: :primary, size: :sm}, slots: ["Small"]}
        ]
      }
    ]
  end
end
