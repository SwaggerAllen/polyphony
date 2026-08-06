defmodule Storybook.Kit.Menu do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.menu/1

  def template do
    """
    <div class="fr stage dark sheet p-4" style="min-height:230px">
      <div class="flex justify-end"><.psb-variation/></div>
      <p class="text-[12.5px] leading-relaxed dim mt-3">Where everything that isn't this screen lives, since the design has no standing navigation. Built on &lt;details&gt;, so it opens with no JavaScript and closes on Escape — a menu holding the sign-out link shouldn't need a live connection to open.</p>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :open_it,
        description:
          "Closed, it is the kit's `.hamb` — borderless, 28px square, the same height as the primary action it sits beside. Open, it is the kit's own sheet and rows.",
        slots: [
          ~s|<:item navigate="#">Your stuff</:item>|,
          ~s|<:item navigate="#">Browse published</:item>|,
          ~s|<:item navigate="#">Settings</:item>|,
          ~s|<:item href="#">Sign out, @wren</:item>|
        ]
      }
    ]
  end
end
