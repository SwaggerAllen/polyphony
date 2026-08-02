defmodule PolyphonyWeb.ArcReviewLive do
  @moduledoc """
  V5 (arc review): the review gate over interpreted arc entries (§6.2, §2.8).
  Proposed entries from scene-close extraction await review before they become
  canon and feed the effective sheet (character arc) or effective world bible
  (world arc). Each can be **accepted**, **rejected**, or **edited** first.
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

    world = ArcEntry.list_proposed_world(Repo, socket.assigns.campaign_id)
    assign(socket, proposed: proposed, world: world)
  end

  def handle_event("accept", %{"id" => id}, socket),
    do: gate(socket, fn n -> ArcEntry.accept(Repo, n) end, id, "Accepted into canon.")

  def handle_event("reject", %{"id" => id}, socket),
    do: gate(socket, fn n -> ArcEntry.reject(Repo, n) end, id, "Rejected — it won't reach canon.")

  def handle_event("edit", %{"entry_id" => id} = params, socket) do
    attrs =
      %{statement: params["statement"]}
      |> maybe_put(:scope, params["scope"])

    gate(socket, fn n -> ArcEntry.edit(Repo, n, attrs) end, id, "Updated.")
  end

  defp maybe_put(attrs, _key, val) when val in [nil, ""], do: attrs
  defp maybe_put(attrs, key, val), do: Map.put(attrs, key, val)

  defp gate(socket, fun, id, msg) do
    safe(socket, fn ->
      fun.(String.to_integer(id))
      {:noreply, socket |> put_flash(:info, msg) |> load()}
    end)
  end

  def render(assigns) do
    ~H"""
    <h1>Arc review</h1>
    <p class="dim">
      Interpreted discoveries awaiting review. Accept to promote to canon, reject to drop,
      or edit the wording first.
    </p>

    <h3>Characters</h3>
    <div :if={@proposed == []} class="list-empty">No character arc to review.</div>
    <div :for={{subject, e} <- @proposed} class="card">
      <span class="badge"><%= subject %></span>
      <span class="faint"><%= e.kind %></span>
      <.review_row e={e} />
    </div>

    <h3>World</h3>
    <div :if={@world == []} class="list-empty">No world arc to review.</div>
    <div :for={e <- @world} class="card">
      <span class="badge">world</span>
      <span class="faint"><%= e.kind %> · <%= e.scope %><%= if e.location_id, do: " · #{e.location_id}" %></span>
      <.review_row e={e} world={true} />
    </div>
    """
  end

  # One proposal: an inline edit form (statement, plus scope for world) with Save,
  # and Accept / Reject actions.
  defp review_row(assigns) do
    assigns = Map.put_new(assigns, :world, false)

    ~H"""
    <form phx-submit="edit" class="stack">
      <input type="hidden" name="entry_id" value={@e.id} />
      <textarea name="statement" rows="2"><%= @e.statement %></textarea>
      <label :if={@world} class="row">
        Reach:
        <select name="scope">
          <option value="global" selected={@e.scope == "global"}>global</option>
          <option value="local" selected={@e.scope == "local"}>local</option>
        </select>
      </label>
      <div class="row">
        <button class="btn sm ghost" type="submit">Save edit</button>
        <button class="btn sm" type="button" phx-click="accept" phx-value-id={@e.id}>Accept</button>
        <button class="btn sm ghost" type="button" phx-click="reject" phx-value-id={@e.id}>
          Reject
        </button>
      </div>
    </form>
    """
  end
end
