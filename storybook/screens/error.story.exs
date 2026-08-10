defmodule Storybook.Screens.Error do
  use PhoenixStorybook.Story, :component

  def container, do: {:div, style: "width:100%"}

  def function, do: &PolyphonyWeb.Screens.Error.screen/1

  # The trace below is a real `Ecto.NoResultsError` shape for this codebase (the mock's
  # was invented and says so) — the storybook is the source of truth, so it follows the
  # real formatting rather than the other way round.
  @detail """
  ** (Ecto.NoResultsError) expected at least one result but got none in query:

  from l0 in Polyphony.ReadModels.LibraryEntry,
    where: l0.id == ^42
  """

  def variations do
    [
      %Variation{
        id: :not_found,
        description:
          "404. Most of these are a mistyped URL or a link that outlived what it pointed at — " <>
            "the person holding it did nothing wrong, so the copy says what happened rather " <>
            "than *something went wrong*. One route out, to the front door: this page must " <>
            "render without a session, so no *back to your library* and no search box.",
        attributes: %{status: 404, request_id: "8dcf43c4-4987"}
      },
      %Variation{
        id: :forbidden,
        description:
          "403, signed in. *This isn't yours* — saying *not found* would send a collaborator " <>
            "looking for a bug instead of asking for access. No request-access control: that " <>
            "is a real feature and this is not the place to invent it, so the page says who " <>
            "to ask rather than pretending to ask for them.",
        attributes: %{status: 403, signed_in: true, request_id: "8dcf43c4-4987"}
      },
      %Variation{
        id: :forbidden_signed_out,
        description:
          "403, signed out. The same fact, and the useful thing to do about it is different: " <>
            "somebody on a second device may well have access under an account they aren't " <>
            "currently in, so the page offers the door. It does **not** promise access after " <>
            "signing in, which it cannot know.",
        attributes: %{status: 403, signed_in: false, request_id: "8dcf43c4-4987"}
      },
      %Variation{
        id: :server_error,
        description:
          "500 with detail — **the ordinary production case**, because `SHOW_ERROR_DETAILS` " <>
            "is on by default and stays that way (a confirmed non-ask). The message admits " <>
            "fault, and the trace sits below it in monospace, set apart rather than styled " <>
            "as an alarm, so the human sentence reads first.",
        attributes: %{status: 500, request_id: "8dcf43c4-4987", detail: @detail}
      },
      %Variation{
        id: :server_error_plain,
        description:
          "500 with detail switched off — what a reader sees whenever the flag is unset. " <>
            "Same message, same request id, no block beneath: the layout has to stand up " <>
            "without the detail carrying its weight, and the id becomes the one thing worth " <>
            "quoting.",
        attributes: %{status: 500, request_id: "8dcf43c4-4987"}
      }
    ]
  end
end
