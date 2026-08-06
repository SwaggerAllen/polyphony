defmodule Storybook.Screens.GroupEditor do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.GroupEditor.screen/1

  defp fact(statement, concealed \\ false),
    do: %{statement: statement, concealed: concealed, audience: nil}

  defp base do
    %{
      name: "The Tidewatch",
      campaign: %{id: "camp-1", name: "The Salt Line"},
      blocks: %{
        "premise" => ["Volunteers who walk the sea wall on nights nobody else will."],
        "appearance" => ["Oilskins, and a lamp each."],
        "temperament" => ["Unhurried. They have seen the water do this before."],
        "backstory" => ["Founded after the year the wall failed twice."]
      },
      facts: [
        fact("They walk the wall in pairs, always."),
        fact("Two of them were paid to look away in the spring.", true)
      ],
      members: [
        %{id: "wren", name: "Wren Ashgrove", hue: "hsl(210 40% 55%)"},
        %{id: "ilias", name: "Ilias", hue: "hsl(40 40% 55%)"}
      ],
      generating: MapSet.new(),
      telling: nil,
      panel: nil,
      dirty: false,
      saved: false
    }
  end

  defp v(id, description, overrides),
    do: %Variation{
      id: id,
      description: description,
      attributes: base() |> Map.merge(overrides) |> Map.put(:id, to_string(id))
    }

  def variations do
    [
      v(
        :written,
        "A group with members and a secret. The secret is what makes this a **membership** rather than a label — a group whose facts are all public grants nothing by belonging to it.",
        %{}
      ),
      v(
        :empty,
        "A new group, before anything is written. Nothing here should read as broken; an empty group is a normal thing to have for a minute.",
        %{
          name: "",
          blocks: %{
            "premise" => [""],
            "appearance" => [""],
            "temperament" => [""],
            "backstory" => [""]
          },
          facts: [],
          members: []
        }
      ),
      v(
        :no_members,
        "Written, but nobody in it yet. Worth its own state because *Tell the members* has nobody to tell, and saying so is better than fanning out to an empty list.",
        %{members: []}
      ),
      v(
        :generating,
        "A field being written. The skeleton is per-field rather than per-screen, so the rest stays editable while one field thinks.",
        %{generating: MapSet.new(["premise"])}
      ),
      v(
        :telling,
        "Being asked whether one fact should reach the members. `telling` is the **index of the fact**, not a flag — the panel names the fact rather than describing the operation, because *tell them what?* is the question. Accepting fans out into one proposal per member, each reviewed on its own; nothing propagates silently.",
        %{telling: 1}
      ),
      v(
        :dirty,
        "Unsaved. The save bar is pinned to the frame rather than the document, because on a phone a save control at the bottom of a long form is a save control nobody finds.",
        %{dirty: true}
      )
    ]
  end
end
