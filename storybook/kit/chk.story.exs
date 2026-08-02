defmodule Storybook.Kit.Chk do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.chk/1

  def template do
    """
    <div class="fr stage dark p-4 flex items-center gap-3">
      <.psb-variation-group/>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :states,
        description:
          "The outlined tick is inherited from a group and can't be individually removed — take the group off instead. That's why it reads differently rather than just being disabled.",
        variations: [
          %Variation{id: :chosen, attributes: %{state: :on}},
          %Variation{id: :via_a_group, attributes: %{state: :via}},
          %Variation{id: :off, attributes: %{state: :off}}
        ]
      }
    ]
  end
end
