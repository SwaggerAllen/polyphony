defmodule Storybook.Kit.Info do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.info/1

  def variations do
    [
      %Variation{
        id: :beside_a_header,
        description:
          "Beside a section header, never inside a menu — one drawer per section, covering the concepts in it, not one popover per setting. The test for whether a label needs one: does it mean something different here than a first-time reader would assume?",
        attributes: %{label: "facts"},
        template: """
        <div class="fr stage dark sheet">
          <div class="px-4 py-3 row flex items-center justify-between" style="background:var(--b2)">
            <span class="flex items-center gap-1.5">
              <span class="lbl dim">What's true about her</span>
              <.psb-variation/>
            </span>
            <button class="btn btn-gh btn-sm">✦ Suggest</button>
          </div>
          <div class="px-4 py-2.5">
            <p class="text-[13px] leading-relaxed">She reads a manifest upside down.</p>
          </div>
        </div>
        """
      }
    ]
  end
end
