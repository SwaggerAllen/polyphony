defmodule PolyphonyWeb.ShareLive do
  @moduledoc """
  Unlisted share links (§B1): readable only with the matching token.

  A share link is a **grant**, so an unlisted campaign opened through one gets the
  reading surface rather than a card that says a story exists — it hands off to
  `BrowseLive`, where the perspective picker and the transcript already live. A second
  reading view for the same object is how the two drift.

  A revoked, deleted or **moderation-hidden** link leads nowhere, and says so without
  saying which: *this link doesn't lead anywhere any more* covers all three, and
  distinguishing them would tell a stranger something about somebody else's account.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.Library
  alias PolyphonyWeb.Screens

  def mount(%{"token" => token}, _session, socket) do
    case Library.get_by_share_token(token) do
      nil ->
        {:ok, assign(socket, page_title: "Not found", entry: nil, payload: nil)}

      # The token travels with the hand-off. It has to: an unlisted story is readable
      # *because* the reader holds the link, and dropping the grant at the door is what
      # forced the receiving screen to stop asking — which made every unlisted story
      # readable by id. Browse remembers it for the life of the reading session.
      %{kind: "campaign", frozen: true} = entry ->
        {:ok, push_navigate(socket, to: ~p"/browse?#{[story: entry.id, t: token]}")}

      entry ->
        {:ok,
         assign(socket,
           page_title: "Shared",
           entry: entry,
           payload: Library.payload(entry)
         )}
    end
  end

  def render(assigns) do
    ~H"""
    <Screens.Share.screen
      current_user={@current_user}
      entry={@entry}
      payload={@payload}
    />
    """
  end
end
