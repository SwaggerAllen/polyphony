defmodule Storybook.Kit.InfoDrawer do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.info_drawer/1

  # The overlay is `position:fixed`, so it covers the catalogue rather than sitting in
  # the frame. That is the point of it and worth seeing — the note says so, since a
  # story you have to press Escape to leave reads as broken otherwise.
  def template do
    """
    <div class="fr stage dark sheet p-4" style="min-height:120px">
      <p class="text-[12.5px] leading-relaxed dim">
        Opens over the screen. Three ways out: the ×, the scrim, and Escape.
      </p>
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :what_a_section_means,
        description:
          "One per section rather than one per setting — the concepts in a section only make sense together. An overlay rather than an inline panel, because on a one-long-scroll authoring screen an inline one lands wherever it happens to sit in the document, which is routinely a screen below the `i` that opened it.",
        attributes: %{title: "About facts", on_close: "noop"},
        slots: [
          "<:intro>Short, flat statements that are true about them — the things they'd never contradict.</:intro>",
          ~s|<:part colour="var(--secret)" name="Secret">Who else starts out knowing it. Nobody, by default.</:part>|,
          ~s|<:part colour="var(--lamp)" name="Always in mind">Whether she carries it every turn. Orthogonal to secret: you can have a secret you rarely think about.</:part>|
        ]
      }
    ]
  end
end
