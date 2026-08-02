defmodule Storybook.Kit.Jump do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.jump/1

  def template do
    """
    <div class="fr stage dark sheet mb-4">
      <.psb-variation/>
      <div class="px-4 py-4">
        <p class="text-[12.5px] leading-relaxed dim">Sits outside the vertical scroller so it stays put and can't blow out the width.</p>
      </div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :jump_bar,
        description: "Long forms — character sheet, world bible.",
        slots: [
          ~s|<:stop on>Premise</:stop>|,
          ~s|<:stop>Appearance</:stop>|,
          ~s|<:stop>Voice</:stop>|,
          ~s|<:stop>Facts</:stop>|,
          ~s|<:stop>Ties</:stop>|,
          ~s|<:stop>Pushed</:stop>|
        ]
      },
      %Variation{
        id: :scrubber,
        description:
          "Same primitive, winding a sheet back. One stop per closed scene — arc is extracted at scene close, so that's the only meaningful resolution.",
        attributes: %{scrub: true},
        slots: [
          ~s|<:stop>Start</:stop>|,
          ~s|<:stop>Scene 1</:stop>|,
          ~s|<:stop>Scene 2</:stop>|,
          ~s|<:stop on>Now</:stop>|
        ]
      }
    ]
  end
end
