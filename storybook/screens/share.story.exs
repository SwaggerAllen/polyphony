defmodule Storybook.Screens.Share do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Share.screen/1

  def variations do
    [
      %Variation{
        id: :dead_link,
        description:
          "A token that no longer resolves — revoked, unpublished, or deleted. This is the *common* case on a shared link rather than an error case, which is why it gets a real screen and not a 404: the person holding the link did nothing wrong.",
        attributes: %{entry: nil, payload: nil}
      },
      %Variation{
        id: :a_world,
        description:
          "A shared world. The blurb is the **cover**, never the bible — a cover is written under instruction to give none of the world's secrets away, so it is the only thing safe to show a stranger.",
        attributes: %{
          entry: %{id: "e1", kind: "world_bible"},
          payload: %{
            name: "Saltmarch",
            cover: "A drowned county that still collects its tolls."
          }
        }
      },
      %Variation{
        id: :a_character,
        description:
          "A shared character. Same rule, different field: a sheet's premise is what a stranger would be told about them, and the facts — which is where concealment lives — are not on this screen at all.",
        attributes: %{
          entry: %{id: "e2", kind: "character"},
          payload: %{
            name: "Wren Ashgrove",
            premise: "Keeps the tide ledger, and keeps it honest, mostly."
          }
        }
      },
      %Variation{
        id: :untitled,
        description:
          "Something shared before it was named. The fallback reads as a description rather than an error, since an unnamed draft is a normal thing to have and a screen saying `nil` is not.",
        attributes: %{entry: %{id: "e3", kind: "world_bible"}, payload: %{}}
      }
    ]
  end
end
