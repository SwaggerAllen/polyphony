defmodule Storybook.Kit.Frame do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.frame/1

  def variations do
    [
      %VariationGroup{
        id: :registers,
        description:
          "The outer decision on every screen. Working surfaces take .stage, reading ones take .page — and both take either theme.",
        variations:
          for register <- [:stage, :page], theme <- [:dark, :light] do
            %Variation{
              id: :"#{register}_#{theme}",
              attributes: %{register: register, theme: theme, class: "sheet p-4 mb-3"},
              slots: [
                """
                <div class="ttl text-[16px] mb-1 font-semibold">#{if register == :stage, do: "Working", else: "Reading"}</div>
                <p class="text-[13px] leading-relaxed dim mb-3">#{if register == :stage, do: "Author and GM play, campaign editor, sheets, library, admin.", else: "Character play and published campaigns. Warmer, quieter, wider measure."}</p>
                <div class="flex gap-1.5">
                  <button class="btn btn-pri btn-sm">Primary</button>
                  <button class="btn btn-gh btn-sm">Ghost</button>
                </div>
                """
              ]
            }
          end
      }
    ]
  end
end
