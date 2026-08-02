defmodule Storybook.Kit.ChipCore do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.chip_core/1

  def template do
    """
    <div class="fr stage dark sheet p-4">
      <p class="text-[13.5px] leading-relaxed mb-1">Signed the register since she was fourteen.</p>
      <.psb-variation/>
      <p class="text-[11.5px] leading-relaxed dim mt-3">A chip rather than a left rule precisely so it composes: a fact can be secret <em>and</em> always in mind. "Always in mind" is the author's vocabulary for what the model would call core — the kit's copy rule is that the model's vocabulary isn't the author's.</p>
    </div>
    """
  end

  def variations, do: [%Variation{id: :default}]
end
