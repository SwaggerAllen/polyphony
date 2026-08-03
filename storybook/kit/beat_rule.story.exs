defmodule Storybook.Kit.BeatRule do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.beat_rule/1

  def template do
    """
    <div class="fr stage dark sheet p-4">
      <.psb-variation/>
      <p class="text-[13px] leading-relaxed dim mt-2">Sticky within the transcript, and plain by design: it records that a beat opened and never changes afterwards. No state, no navigation — and it is the only place a beat number appears.</p>
    </div>
    """
  end

  def variations, do: [%Variation{id: :beat, attributes: %{beat: 4}}]
end
