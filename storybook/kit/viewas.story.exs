defmodule Storybook.Kit.Viewas do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.viewas/1

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
        id: :viewpoints,
        description:
          "Every viewpoint, one control. The hue is the only difference — omniscient takes --bc, limited omniscient --lamp, a spectator --bcm, and a character their voice colour.",
        variations: [
          %Variation{id: :omniscient, attributes: %{label: "Omniscient", colour: "var(--bc)"}},
          %Variation{
            id: :limited,
            attributes: %{label: "Everyone shared", colour: "var(--lamp)"}
          },
          %Variation{id: :spectator, attributes: %{label: "Spectator", colour: "var(--bcm)"}},
          %Variation{id: :wren, attributes: %{label: "Wren", colour: "var(--v1)"}},
          %Variation{id: :ilias, attributes: %{label: "Ilias", colour: "var(--v2)"}}
        ]
      },
      %Variation{
        id: :fixed,
        description:
          "Without a caret when the viewpoint can't be switched — a preview banner rather than a picker.",
        attributes: %{label: "Previewing as Wren", colour: "var(--v1)", caret: false}
      },
      %Variation{
        id: :in_a_header,
        description:
          "Its one position: top right of the header. Play and the published reading screen use this markup unchanged.",
        attributes: %{label: "Ilias", colour: "var(--v2)", tag: "button"},
        template: """
        <div class="fr page dark sheet">
          <div class="px-4 py-3 row flex items-center justify-between gap-2">
            <div class="min-w-0">
              <div class="lbl dim">The Salt Line</div>
              <div class="ttl text-[15px] mt-0.5 truncate font-semibold">The quay</div>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <.psb-variation/>
              <span class="pill">⋯</span>
            </div>
          </div>
        </div>
        """
      }
    ]
  end
end
