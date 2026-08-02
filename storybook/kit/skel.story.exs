defmodule Storybook.Kit.Skel do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.skel/1

  def template do
    """
    <div class="fr stage dark sheet p-4">
      <div class="mb-1.5"><.psb-variation/></div>
    </div>
    """
  end

  def variations do
    [
      %Variation{id: :long, attributes: %{width: "92%"}},
      %Variation{id: :short, attributes: %{width: "64%"}}
    ]
  end
end
