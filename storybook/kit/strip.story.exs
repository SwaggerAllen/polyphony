defmodule Storybook.Kit.Strip do
  use PhoenixStorybook.Story, :component

  # Variations render at the width they'd have on a screen: several of these
  # components (the status strip, marked rows, tabs) are full-bleed by nature and
  # read wrong shrink-wrapped.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Kit.strip/1

  def template do
    """
    <div class="fr page dark sheet mb-3"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :your_turn,
        description:
          "Above the composer in both registers: a slot per cast member, then one sentence. No beat number — the transcript rule owns that.",
        attributes: %{sentence: "Your turn.", tone: "var(--lamp)"},
        slots: [
          ~s|<:slot_item label="WREN" state={:took} colour="var(--v1)"/>|,
          ~s|<:slot_item label="YOU" state={:now} you/>|,
          ~s|<:slot_item label="CORR" state={:wait}/>|
        ]
      },
      %Variation{
        id: :someone_else_writing,
        attributes: %{sentence: "Wren is writing. You're next."},
        slots: [
          ~s|<:slot_item label="WREN" state={:now}/>|,
          ~s|<:slot_item label="YOU" state={:wait} you/>|,
          ~s|<:slot_item label="CORR" state={:wait}/>|
        ]
      },
      %Variation{
        id: :you_passed,
        attributes: %{sentence: "You passed. Mother Corrigan is taking her turn."},
        slots: [
          ~s|<:slot_item label="WREN" state={:took} colour="var(--v1)"/>|,
          ~s|<:slot_item label="YOU" state={:pass} you/>|,
          ~s|<:slot_item label="CORR" state={:now}/>|
        ]
      },
      %Variation{
        id: :a_turn_failed,
        description: "Pencil, because a failure is a correction — and it points at itself.",
        attributes: %{sentence: "Her turn didn't come through.", tone: "var(--pencil)"},
        slots: [
          ~s|<:slot_item label="WREN" state={:took} colour="var(--v1)"/>|,
          ~s|<:slot_item label="YOU" state={:took} colour="var(--v2)"/>|,
          ~s|<:slot_item label="CORR" state={:fail}/>|,
          ~s|<:aside><span class="text-[15px] leading-none shrink-0" style="color:var(--pencil)">↓</span></:aside>|
        ]
      },
      %Variation{
        id: :a_full_cast,
        description:
          "Slots flex, so names become initials around six and the row never wraps. The strip is filtered exactly like the transcript — a viewer only gets slots for people they know are there.",
        attributes: %{sentence: "Sable is writing. Two turns until yours."},
        slots: [
          ~s|<:slot_item label="W" state={:took} colour="var(--v1)"/>|,
          ~s|<:slot_item label="I" state={:took} colour="var(--v2)"/>|,
          ~s|<:slot_item label="C" state={:fail}/>|,
          ~s|<:slot_item label="S" state={:now}/>|,
          ~s|<:slot_item label="P" state={:wait} you/>|,
          ~s|<:slot_item label="O" state={:pass}/>|,
          ~s|<:slot_item label="H" state={:wait}/>|,
          ~s|<:slot_item label="T" state={:wait}/>|
        ]
      },
      %Variation{
        id: :slots_are_perspectives,
        description:
          "A slot with `patch` becomes a link: tapping a person puts you behind their eyes. " <>
            "It patches rather than navigates, because switching perspective is the same " <>
            "screen on the same scene. The one you are already in carries no link, so it " <>
            "isn't offering to take you where you are.",
        attributes: %{sentence: "Your turn."},
        slots: [
          ~s|<:slot_item label="WREN" state={:took} colour="var(--v1)" patch="/play/demo?as=wren"/>|,
          ~s|<:slot_item label="YOU" state={:now} you/>|,
          ~s|<:slot_item label="CORR" state={:wait} patch="/play/demo?as=corr"/>|
        ]
      }
    ]
  end
end
