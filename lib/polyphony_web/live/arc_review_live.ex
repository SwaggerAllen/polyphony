defmodule PolyphonyWeb.ArcReviewLive do
  @moduledoc """
  V5 (arc review): the review gate over interpreted arc entries. Proposed entries
  from scene-close extraction await acceptance before they become canon and feed the
  effective sheet.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Library, Repo}
  alias Polyphony.ReadModels.ArcEntry

  def mount(%{"campaign_id" => id}, _session, socket) do
    entry = Library.get(id)
    campaign = entry && Library.payload(entry)
    subjects = (campaign && campaign[:character_ids]) || []

    {:ok,
     socket |> assign(page_title: "Arc review", campaign_id: id, subjects: subjects) |> load()}
  end

  defp load(socket) do
    proposed =
      Enum.flat_map(socket.assigns.subjects, fn subject ->
        Repo |> ArcEntry.list_proposed(subject) |> Enum.map(&{subject, &1})
      end)

    assign(socket, proposed: proposed)
  end

  def handle_event("accept", %{"id" => id}, socket) do
    ArcEntry.accept(Repo, String.to_integer(id))
    {:noreply, socket |> put_flash(:info, "Accepted into canon.") |> load()}
  end

  def render(assigns) do
    ~H"""
    <h1>Arc review</h1>
    <p class="dim">Interpreted discoveries awaiting review. Accept to promote to canon.</p>

    <div :if={@proposed == []} class="list-empty">Nothing to review.</div>
    <div :for={{subject, e} <- @proposed} class="card">
      <div class="row">
        <div>
          <span class="badge"><%= subject %></span>
          <span class="faint"><%= e.kind %></span>
          <p style="margin:.3rem 0 0;"><%= e.statement %></p>
        </div>
        <div class="spacer"></div>
        <button class="btn sm" phx-click="accept" phx-value-id={e.id}>Accept</button>
      </div>
    </div>
    """
  end
end
