defmodule Storybook.Kit.FailMove do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.fail_move/1

  def template do
    """
    <div class="fr stage dark sheet p-4">
      <div class="mb-3"><.psb-variation/></div>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :didnt_generate,
        description:
          "Rendered in the transcript at the beat it happened, not in a banner — the gap in the fiction is visible where the gap is. Failures are scoped per viewer, so a player only ever sees their own.",
        attributes: %{
          title: "Mother Corrigan didn't generate",
          detail: "Moved to the end of the beat."
        }
      },
      %Variation{
        id: :model_busy,
        description:
          "The copy rule: say what went wrong and what happens next, never the rule that was broken.",
        attributes: %{
          title: "The model is busy",
          detail:
            "It usually clears in a few minutes, and a scene would be struggling too until it does."
        }
      }
    ]
  end
end
