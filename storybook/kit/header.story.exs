defmodule Storybook.Kit.Header do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.header/1

  def template do
    """
    <div class="fr stage dark sheet mb-3">
      <.psb-variation/>
      <div class="px-4 py-4"><p class="text-[12.5px] leading-relaxed dim">Every screen with a title uses this markup — play, the reading screen, the library, the campaign editor, admin. That's what makes moving between them feel like one product.</p></div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :with_context,
        description:
          "Campaign name small, the scene's location as the title, controls top right — the kit's own spec. Play and the published reading screen use it unchanged; only the bottom bar differs.",
        attributes: %{title: "The quay", eyebrow: "The Salt Line"},
        slots: [
          ~s|<:actions><span class="viewas" style="--vc:var(--v2)"><i></i>Ilias ▾</span><span class="pill">⋯</span></:actions>|
        ]
      },
      %Variation{
        id: :plain,
        description: "Without context above it, the title takes the larger size.",
        attributes: %{title: "Your stuff"},
        slots: [~s|<:actions><button class="btn btn-pri btn-sm">New campaign</button></:actions>|]
      },
      %Variation{
        id: :drill_down,
        description:
          "The back chevron is how you leave a screen you drilled into — there is no standing navigation to fall back on.",
        attributes: %{title: "Kettleworth", back: "/library"}
      }
    ]
  end
end
