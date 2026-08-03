defmodule Storybook.Kit.WorldMove do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.world_move/1

  def variations do
    [
      %Variation{
        id: :stage,
        description:
          "Working register: rules above and below, a hanging dash, and the attribution. Spectral doing body work — the one place it does.",
        attributes: %{register: :stage},
        slots: ["The tide bell rings twice. An arrival nobody logged."],
        template: """
        <div class="fr stage dark sheet p-4"><.psb-variation/></div>
        """
      },
      %Variation{
        id: :page,
        description:
          "Reading register: the dash and the attribution fall away and the line simply gets bigger.",
        attributes: %{register: :page},
        slots: ["The tide bell rings twice. An arrival nobody logged."],
        template: """
        <div class="fr page dark sheet p-4"><.psb-variation/></div>
        """
      }
    ]
  end
end
