defmodule Storybook.Screens.Resume do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Resume.screen/1

  @user %{id: "u1", username: "wren", email: "wren@example.com"}

  def variations do
    [
      %Variation{
        id: :offer,
        description:
          "Reached on a remembered device, so the screen knows who you are before you have signed in. The address is **redacted** for exactly that reason — printing it whole hands it to whoever picked the laptop up.",
        attributes: %{user: @user}
      },
      %Variation{
        id: :sent,
        description:
          "After asking for the link. Same redaction, and the same escape routes as sign-in, because being on a remembered device does not make a mistyped account any easier to get out of.",
        attributes: %{user: @user, sent: true}
      },
      %Variation{
        id: :dev_link,
        description:
          "`:expose_magic_link` again — dev only, pinned false in prod. Worth seeing beside the others: this is the one control on the screen that would be a full account takeover if it ever shipped.",
        attributes: %{user: @user, sent: true, dev_link: "/auth/verify/example-token"}
      }
    ]
  end
end
