defmodule Storybook.Kit.SkelLines do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.skel_lines/1

  def template do
    """
    <div class="fr stage dark sheet p-4"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :a_field_being_written,
        description:
          "Uneven widths on purpose — prose doesn't come in equal lines, and identical bars read as a table. It goes where the text will go, replacing the empty field rather than sitting beside it: an empty input is exactly what nothing-happened looks like.",
        attributes: %{lines: ["100%", "94%", "61%"], label: "Writing their backstory"}
      },
      %Variation{
        id: :one_more_paragraph,
        description: "A paragraph on its way to the end of a field that already has some.",
        attributes: %{lines: ["96%", "68%"]}
      },
      %Variation{
        id: :a_batch_of_suggestions,
        description: "Rows, because suggestions arrive as a batch of rows.",
        attributes: %{lines: ["86%", "70%", "78%"]}
      }
    ]
  end
end
