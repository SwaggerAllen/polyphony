defmodule PolyphonyWeb.Screens.Share do
  @moduledoc """
  A shared link, as markup.

  The screen somebody arrives on from a link another person sent them — which makes them
  the visitor with the least idea what this is and the fewest ways to find out. It has a
  nil clause for a token that resolves to nothing, because an expired or revoked link is
  the common case here rather than an error.
  """
  use PolyphonyWeb, :html

  alias PolyphonyWeb.{Kit, Layouts}

  attr(:entry, :any,
    default: nil,
    doc: "the library entry behind the token, or nil if it no longer resolves"
  )

  attr(:payload, :any,
    default: nil,
    doc: "the entry's payload, already unwrapped by the LiveView"
  )

  attr(:current_user, :map, default: nil)

  def screen(%{entry: nil} = assigns) do
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

  def screen(assigns) do
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
