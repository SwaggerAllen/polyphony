defmodule PolyphonyWeb.ShareLive do
  @moduledoc "Unlisted share links (§B1): readable only with the matching token."
  use PolyphonyWeb, :live_view

  alias Polyphony.Library

  def mount(%{"token" => token}, _session, socket) do
    case Library.get_by_share_token(token) do
      nil ->
        {:ok, socket |> assign(page_title: "Not found", entry: nil)}

      entry ->
        {:ok, assign(socket, page_title: "Shared", entry: entry, payload: Library.payload(entry))}
    end
  end

  def render(%{entry: nil} = assigns) do
    ~H"""
    <div class="card"><h1>Not found</h1><p class="dim">This share link is invalid or was revoked.</p></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="card">
      <span class="badge unlisted">unlisted · shared with you</span>
      <h1><%= Map.get(@payload, :name) || "Untitled" %></h1>
      <p class="faint"><%= @entry.kind %></p>
    </div>
    """
  end
end
