defmodule Storybook.Kit.Writing do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.writing/1

  def template do
    """
    <div class="fr stage dark sheet p-4"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :a_turn_arriving,
        description:
          "The transcript is the only place the answer can appear, so it is the only place the waiting belongs. Same voice-coloured rule as a thought, because it is about to become one — the placeholder and the line that replaces it are the same shape in the same colour, so nothing jumps when the words arrive.",
        attributes: %{colour: "var(--v1)", note: "Wren Ashgrove is writing their turn…"}
      },
      %Variation{
        id: :someone_else,
        description:
          "The attribution line does the same work it does on a finished move: it says whose turn this is while there is nothing else to go on. A spinner in a status bar can't.",
        attributes: %{
          colour: "var(--v3)",
          note: "Bram Toller is writing their turn…",
          lines: ["92%", "100%", "70%", "41%"]
        }
      }
    ]
  end
end
