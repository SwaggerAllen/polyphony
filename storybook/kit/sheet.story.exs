defmodule Storybook.Kit.Sheet do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.sheet/1

  def template do
    """
    <div class="fr stage dark p-4">
      <.psb-variation/>
    </div>
    """
  end

  def variations do
    [
      %Variation{
        id: :with_rows,
        description: "The kit's one container, and the ruled row that lives in it.",
        slots: [
          """
          <div class="px-4 py-2.5 row flex items-center justify-between gap-2">
            <span class="text-[13px] font-semibold">A row</span>
            <span class="dim text-[14px]">›</span>
          </div>
          <div class="px-4 py-2.5 row flex items-center justify-between gap-2">
            <span class="text-[13px] font-semibold">Another</span>
            <span class="pill dim">status</span>
          </div>
          <div class="px-4 py-3"><div class="field px-3 py-2 text-[13px] dim">A field</div></div>
          """
        ]
      }
    ]
  end
end
