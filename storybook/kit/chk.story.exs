defmodule Storybook.Kit.Chk do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.chk/1

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
        id: :states,
        description:
          "The outlined tick is inherited from a group and can't be individually removed — take the group off instead. That's why it reads differently rather than just being disabled.",
        variations: [
          %Variation{id: :chosen, attributes: %{state: :on}},
          %Variation{id: :via_a_group, attributes: %{state: :via}},
          %Variation{id: :off, attributes: %{state: :off}}
        ]
      },
      %Variation{
        id: :on_a_real_checkbox,
        description:
          "The form version, and the one to reach for on a form: a real <input type=\"checkbox\"> immediately before it, visually hidden, so the control is focusable, keyboard-operable, named and submitted — and the tick is only a picture of it. Drawing two boxes and hiding one with a utility does not work: the kit loads after Tailwind, so .chk's own display:flex outranks .hidden and both ticks render.",
        attributes: %{state: :off},
        template: """
        <div class="fr stage dark p-4">
          <label class="flex items-center gap-2.5 cursor-pointer">
            <input type="checkbox" class="sr-only peer" aria-label="Tick me" checked />
            <.psb-variation/>
            <span class="text-[13px]">Tick me — the box is driven by the input</span>
          </label>
        </div>
        """
      }
    ]
  end
end
