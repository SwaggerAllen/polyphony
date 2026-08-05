defmodule Storybook.Kit.Dot do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.dot/1

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
        id: :semantics,
        description:
          "The smallest carrier of the four semantics. It never decorates — if a dot is there, the colour is saying something: lamp is now, ok is done, pencil is a correction, secret is concealed.",
        variations: [
          %Variation{id: :now, attributes: %{colour: "var(--lamp)"}},
          %Variation{id: :done, attributes: %{colour: "var(--ok)"}},
          %Variation{id: :wrong, attributes: %{colour: "var(--pencil)"}},
          %Variation{id: :secret, attributes: %{colour: "var(--secret)"}},
          %Variation{id: :a_voice, attributes: %{colour: "var(--v1)"}}
        ]
      },
      %VariationGroup{
        id: :happening_now,
        description:
          "Breathing means it is happening this second, not merely that it is coloured as now. Only ever on lamp, for the same reason lamp is only ever now: one moving thing on screen, so motion means one thing. It stops under prefers-reduced-motion and keeps a static halo, because the dot is never the only signal.",
        variations: [
          %Variation{id: :live, attributes: %{colour: "var(--lamp)", live: true}},
          %Variation{id: :still, attributes: %{colour: "var(--lamp)"}}
        ]
      }
    ]
  end
end
