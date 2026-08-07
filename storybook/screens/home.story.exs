defmodule Storybook.Screens.Home do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Home.screen/1

  def variations do
    [
      %Variation{
        id: :signed_out,
        description:
          "The only screen whose job is to explain what this is. Everything below the fold is argument rather than product, because somebody arriving here has no reason to care yet.",
        attributes: %{}
      },
      %Variation{
        id: :signed_in,
        description:
          "The same page for somebody who already has work here. The corner menu is the whole difference and it is the point — a returning visitor needs a route to their own campaigns rather than the pitch they have already read.",
        attributes: %{current_user: %{id: "u1", username: "wren", role: "user"}}
      }
    ]
  end
end
