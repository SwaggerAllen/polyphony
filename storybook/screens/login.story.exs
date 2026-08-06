defmodule Storybook.Screens.Login do
  use PhoenixStorybook.Story, :component

  # Screens are full-bleed by nature — they set their own frame and centre themselves
  # in the viewport, so shrink-wrapping one reads as a different design.
  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Login.screen/1

  def variations do
    [
      %Variation{
        id: :signed_out,
        description:
          "The way in. Two fields rather than one that takes either, so the address keeps `type=\"email\"` and the browser catches a typo'd domain before it becomes a silent no-match.",
        attributes: %{}
      },
      %Variation{
        id: :sent,
        description:
          "After a link goes out. This state is the whole experience of a passwordless sign-in, so it carries both escape routes and the spam line *before* anyone needs them.",
        attributes: %{sent_to: "wren@example.com"}
      },
      %Variation{
        id: :sent_to_nobody,
        description:
          "The same screen for an address with no account — and that is the point. It is identical to the state above, because an enumeration oracle on the login screen is a worse trade than a moment of ambiguity for somebody who mistyped. Nothing here should ever be made to differ.",
        attributes: %{sent_to: "nobody@example.com"}
      },
      %Variation{
        id: :dev_link_exposed,
        description:
          "`:expose_magic_link`, which is dev-only and pinned false in prod by a test: it hands a working session to anyone who types a known address. Here so the control is visible when reviewing, rather than only ever seen by accident.",
        attributes: %{sent_to: "wren@example.com", dev_link: "/auth/verify/example-token"}
      },
      %Variation{
        id: :signed_in,
        description:
          "Reached with a session already live. The corner menu is the only difference, and it is the reason this screen takes `current_user` at all — a signed-in visitor needs a route out that isn't signing in again.",
        attributes: %{current_user: %{id: "u1", username: "wren", role: "user"}}
      }
    ]
  end
end
