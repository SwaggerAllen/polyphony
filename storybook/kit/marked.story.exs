defmodule Storybook.Kit.Marked do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.marked/1

  def template do
    """
    <div class="fr stage dark sheet p-4">
      <div class="mb-3"><.psb-variation/></div>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :facts,
        description:
          "Only one thing can own the left border, so secrecy takes it — visibility has consequences — and always-in-mind is a chip instead, letting the two compose.",
        variations: [
          %Variation{
            id: :secret,
            attributes: %{mark: :secret},
            slots: [
              """
              <p class="text-[13.5px] leading-relaxed">Signing for the Kestrel since March.</p>
              <div class="flex items-center gap-1.5 mt-1">
                <span class="dot" style="background:var(--secret)"></span>
                <span class="lbl" style="color:var(--secret)">Secret · 2 know</span>
              </div>
              """
            ]
          },
          %Variation{
            id: :core,
            attributes: %{mark: :core},
            slots: [
              ~s|<p class="text-[13.5px] leading-relaxed">Signed the register since she was fourteen.</p>|
            ]
          }
        ]
      },
      %VariationGroup{
        id: :pressures,
        description:
          "Pencil for what she won't do, violet for what she can't stop. Direction lives in the group heading, never the wording.",
        variations: [
          %Variation{
            id: :bound,
            attributes: %{mark: :bound},
            slots: [
              """
              <div class="text-[13.5px] font-semibold">Name her father</div>
              <p class="text-[12.5px] leading-relaxed dim"><span class="lbl">until</span> someone she loves is hurt by it</p>
              """
            ]
          },
          %Variation{
            id: :compel,
            attributes: %{mark: :compel},
            slots: [
              """
              <div class="text-[13.5px] font-semibold">Cover for her father</div>
              <p class="text-[12.5px] leading-relaxed dim"><span class="lbl">and now</span> she lets the silences sit</p>
              """
            ]
          }
        ]
      },
      %VariationGroup{
        id: :arc,
        description:
          "An arc entry's whole life: proposed by extraction, accepted into canon, or dropped.",
        variations: [
          %Variation{
            id: :proposed,
            attributes: %{mark: :prop},
            slots: [
              """
              <p class="text-[13px] leading-relaxed">She has stopped signing in her mother's hand.</p>
              <div class="lbl mt-0.5" style="color:var(--lamp)">Proposed</div>
              """
            ]
          },
          %Variation{
            id: :canon,
            attributes: %{mark: :canon},
            slots: [
              """
              <p class="text-[13px] leading-relaxed">She has stopped signing in her mother's hand.</p>
              <div class="lbl mt-0.5" style="color:var(--ok)">True since scene 3</div>
              """
            ]
          },
          %Variation{
            id: :dropped,
            attributes: %{mark: :drop},
            slots: [
              """
              <p class="text-[13px] leading-relaxed">Cover for her father.</p>
              <div class="lbl dim mt-0.5">Broke in scene 3</div>
              """
            ]
          }
        ]
      },
      %VariationGroup{
        id: :other,
        variations: [
          %Variation{
            id: :urgent,
            attributes: %{mark: :urgent, class: "px-2.5 py-2 rounded-r-lg"},
            slots: [
              ~s|<p class="text-[13px] leading-relaxed">Reported passage, or child-safety lane.</p>|
            ]
          },
          %Variation{
            id: :was,
            description: "Superseded by an arc revision. Nothing is deleted, only replaced.",
            attributes: %{mark: :was},
            slots: [~s|<p class="text-[13px] leading-relaxed">Replaced by an arc revision.</p>|]
          },
          %Variation{
            id: :archived,
            description: "Archive is a filter, off by default everywhere — filed, not deleted.",
            attributes: %{mark: :arch, class: "flex items-center gap-2"},
            slots: [
              ~s|<span class="av" style="background:var(--v4)"></span><span class="text-[13px]">Archived — filed, not deleted</span>|
            ]
          }
        ]
      }
    ]
  end
end
