defmodule Storybook.Kit.ViewasSelect do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.viewas_select/1

  def template do
    """
    <div class="fr stage dark p-4">
      <.psb-variation-group/>
    </div>
    """
  end

  def variations do
    [
      %VariationGroup{
        id: :switchable,
        description:
          "The switchable perspective control: the same pill as `viewas`, wrapped round a select. " <>
            "Three screens had grown their own bare `<select class=\"viewas\">`, and `appearance:none` " <>
            "— what makes it a pill rather than an OS widget — had taken the platform's chevron with " <>
            "it, leaving a control that read as a label. The ▾ sits outside the select for that reason.",
        variations: [
          %Variation{
            id: :omniscient,
            attributes: %{id: "sb-omniscient", label: "Viewing as", colour: "var(--bc)"},
            slots: [
              ~s|<option selected>Omniscient</option>|,
              ~s|<option>Wren</option>|,
              ~s|<option>Ilias</option>|
            ]
          },
          %Variation{
            id: :as_a_character,
            attributes: %{id: "sb-wren", label: "Viewing as", colour: "var(--v1)"},
            slots: [
              ~s|<option>Omniscient</option>|,
              ~s|<option selected>Wren</option>|,
              ~s|<option>Ilias</option>|
            ]
          },
          %Variation{
            id: :previewing,
            attributes: %{id: "sb-stranger", label: "Preview as", colour: "var(--secret)"},
            slots: [
              ~s|<option>Omniscient</option>|,
              ~s|<option selected>A stranger</option>|
            ]
          }
        ]
      },
      %Variation{
        id: :grouped,
        description:
          "Options group where the reading screen needs them to — what this snapshot can show " <>
            "you, and what it can't. The control doesn't change shape for it.",
        attributes: %{id: "sb-reading", label: "Reading as", colour: "var(--bcm)"},
        slots: [
          ~s|<optgroup label="Who can show you this"><option selected>Everyone shared</option><option>Wren</option></optgroup>|,
          ~s|<optgroup label="Not in this one"><option>Ilias — wasn't there</option></optgroup>|
        ]
      },
      %Variation{
        id: :in_a_header,
        description: "Its one position, top right, exactly as the static form sits.",
        attributes: %{id: "sb-header", label: "Viewing as", colour: "var(--v2)"},
        slots: [~s|<option selected>Ilias</option>|, ~s|<option>Omniscient</option>|],
        template: """
        <div class="fr stage dark sheet">
          <div class="px-4 py-3 row flex items-center justify-between gap-2">
            <div class="min-w-0">
              <div class="lbl dim">The Salt Line</div>
              <div class="ttl text-[15px] mt-0.5 truncate font-semibold">The quay</div>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <.psb-variation/>
              <span class="pill">⋯</span>
            </div>
          </div>
        </div>
        """
      }
    ]
  end
end
