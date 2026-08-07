defmodule Storybook.Screens.Signup do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Signup.screen/1

  def variations do
    [
      %Variation{
        id: :invited,
        description:
          "The ordinary way in. The consent boxes are real checkbox inputs with labels — a consent you cannot reach with a keyboard is not a consent — and the username rule is stated *before* anybody can break it, because a rule you only learn by failing is a rule the form kept to itself.",
        attributes: %{id: "invited"}
      },
      %Variation{
        id: :first_account,
        description:
          "The very first account on a fresh install, which skips the invite because there is nobody to have sent one. Easy to forget exists and impossible to reach twice.",
        attributes: %{id: "first", first?: true}
      },
      %Variation{
        id: :invite_used,
        description:
          "A spent invite. The copy points at the person who sent it rather than at us, since asking them for another is the actual next step.",
        attributes: %{
          id: "used",
          field: :invite,
          error: "This one's been used. Invites work once — ask whoever sent it for another."
        }
      },
      %Variation{
        id: :username_taken,
        description:
          "A field-level error. It sits on the field rather than at the top, so the answer is beside the question.",
        attributes: %{id: "taken", field: :username, error: "Taken. Try something else."}
      },
      %Variation{
        id: :turned_away,
        description:
          "An unchecked attestation **ends** the signup rather than limiting it. There is no retry and no go-back — a door that reopens on the same screen isn't a door. Nothing was stored: no row, no email, and the invite is not redeemed, so whoever sent it can pass it on.",
        attributes: %{id: "away", turned_away: true}
      }
    ]
  end
end
