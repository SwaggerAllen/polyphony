defmodule PolyphonyWeb.BrowseLive do
  @moduledoc "V9 (public browse): published campaigns and characters, readable signed-out."
  use PolyphonyWeb, :live_view

  alias Polyphony.Library

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Browse",
       campaigns: Library.list_public("campaign"),
       characters: Library.list_public("character")
     )}
  end

  def render(assigns) do
    ~H"""
    <h1>Published</h1>

    <h2>Campaigns</h2>
    <div :if={@campaigns == []} class="list-empty">No published campaigns yet.</div>
    <div :for={e <- @campaigns} class="card">
      <h3><%= name(e) %></h3>
      <p class="faint">A published, self-contained campaign snapshot.</p>
    </div>

    <h2>Characters</h2>
    <div :if={@characters == []} class="list-empty">No published characters yet.</div>
    <div :for={e <- @characters} class="card">
      <h3><%= name(e) %></h3>
    </div>
    """
  end

  defp name(e) do
    case Library.payload(e) do
      %{name: n} when is_binary(n) -> n
      _ -> "Untitled"
    end
  end
end
