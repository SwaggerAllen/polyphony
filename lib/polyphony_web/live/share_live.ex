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
  alias PolyphonyWeb.{Kit, Layouts}

  def mount(%{"token" => token}, _session, socket) do
    case Library.get_by_share_token(token) do
      nil ->
        {:ok, assign(socket, page_title: "Not found", entry: nil, payload: nil)}

      %{kind: "campaign", frozen: true} = entry ->
        {:ok, push_navigate(socket, to: ~p"/browse?#{[story: entry.id]}")}

      entry ->
        {:ok,
         assign(socket,
           page_title: "Shared",
           entry: entry,
           payload: Library.payload(entry)
         )}
    end
  end

  def render(%{entry: nil} = assigns) do
    ~H"""
    <Kit.frame register={:page} class="relative flex flex-col min-h-[100dvh] items-center justify-center p-4">
      <Layouts.corner_menu current_user={@current_user} />
      <Kit.sheet class="w-full max-w-sm p-4">
        <div class="ttl text-[15px] font-semibold mb-1.5">Nothing here</div>
        <p class="text-[13px] leading-relaxed dim">
          This link doesn't lead anywhere any more. It may have been unpublished.
        </p>
      </Kit.sheet>
    </Kit.frame>
    """
  end

  def render(assigns) do
    ~H"""
    <Kit.frame register={:page} class="relative flex flex-col min-h-[100dvh] items-center justify-center p-4">
      <Layouts.corner_menu current_user={@current_user} />
      <Kit.sheet class="w-full max-w-sm">
        <Kit.row class="px-4 py-3" style="background:var(--b2)">
          <div class="lbl dim mb-1">Shared with you</div>
          <div class="ttl text-[16px] font-semibold"><%= name(@payload, @entry.kind) %></div>
        </Kit.row>
        <div :if={blurb(@payload)} class="px-4 py-3">
          <p class="text-[13px] leading-relaxed"><%= blurb(@payload) %></p>
        </div>
        <div class="px-4 py-3">
          <p class="text-[11px] leading-relaxed dim">
            An unlisted link is a grant, not a listing — it's reachable by whoever has it and
            by nobody else.
          </p>
        </div>
      </Kit.sheet>
    </Kit.frame>
    """
  end

  defp name(%{name: n}, _kind) when is_binary(n) and n != "", do: n
  defp name(_payload, kind), do: "An untitled #{String.replace(kind, "_", " ")}"

  # Only the outward blurb, never the thing itself: a world's cover is written under
  # instruction to give none of its secrets away (§2.12), and a sheet's premise is what
  # a stranger would be told.
  defp blurb(%{cover: c}) when is_binary(c) and c != "", do: c
  defp blurb(%{premise: p}) when is_binary(p) and p != "", do: p
  defp blurb(_), do: nil
end
