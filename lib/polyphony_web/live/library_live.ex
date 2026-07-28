defmodule PolyphonyWeb.LibraryLive do
  @moduledoc """
  V9 (library): the owner's authored entities. Everything is scoped through
  `Polyphony.Owner` (the §P2 indirection) — the view never speaks a raw user id.
  Create characters / bibles / campaigns; manage visibility; archive / delete.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Library", filter: "all", query: "") |> load()}
  end

  defp load(socket) do
    owner = Owner.of(socket.assigns.current_user)
    entries = Library.list_for_owner(owner)
    socket |> assign(owner: owner, entries: entries) |> assign_shown()
  end

  # The visible slice: filter the loaded owned entries by kind, and a
  # case-insensitive substring match on the (decoded) name.
  defp assign_shown(socket) do
    %{entries: entries, filter: filter, query: query} = socket.assigns
    q = query |> to_string() |> String.trim() |> String.downcase()

    shown =
      entries
      |> Enum.filter(fn e -> filter in ["all", e.kind] end)
      |> Enum.filter(fn e -> q == "" or String.contains?(String.downcase(entry_name(e)), q) end)

    assign(socket, :shown, shown)
  end

  def handle_event("new", %{"kind" => kind, "name" => name}, socket) when name != "" do
    safe(socket, fn ->
      payload = blank_payload(kind, name)
      Library.put(%{owner: socket.assigns.owner, kind: kind, payload: payload})
      {:noreply, socket |> put_flash(:info, "Created #{kind} “#{name}”.") |> load()}
    end)
  end

  def handle_event("new", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Give it a name first.")}

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(filter: params["kind"] || "all", query: params["q"] || "")
     |> assign_shown()}
  end

  def handle_event("visibility", %{"eid" => id, "visibility" => vis}, socket) do
    safe(socket, fn ->
      Library.set_visibility(id, vis)
      {:noreply, load(socket)}
    end)
  end

  def handle_event("archive", %{"id" => id}, socket) do
    safe(socket, fn ->
      Library.archive(id)
      {:noreply, socket |> put_flash(:info, "Archived.") |> load()}
    end)
  end

  def handle_event("delete", %{"id" => id}, socket) do
    safe(socket, fn ->
      Library.soft_delete(id)
      {:noreply, socket |> put_flash(:info, "Deleted (recoverable).") |> load()}
    end)
  end

  defp blank_payload("character", name), do: %CharacterSheet{name: name, status: :full}
  defp blank_payload("world_bible", name), do: %WorldBible{name: name}

  defp blank_payload("campaign", name),
    do: %{kind: :campaign, name: name, character_ids: [], bible_id: nil, scenes: []}

  defp blank_payload(_other, name), do: %{name: name}

  # ── Render ─────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <h1>Your library</h1>

    <div class="card">
      <form phx-submit="new" class="row">
        <select name="kind" style="width:auto;">
          <option value="character">Character</option>
          <option value="world_bible">World bible</option>
          <option value="campaign">Campaign</option>
        </select>
        <input type="text" name="name" placeholder="Name…" style="flex:1;" />
        <button class="btn" type="submit">Create</button>
      </form>
    </div>

    <div :if={@entries == []} class="list-empty">Nothing here yet. Create a character or a campaign to begin.</div>

    <form :if={@entries != []} id="library-filter" phx-change="filter" class="row library-filter">
      <select name="kind" style="width:auto;">
        <option value="all" selected={@filter == "all"}>All types</option>
        <option value="character" selected={@filter == "character"}>Characters</option>
        <option value="world_bible" selected={@filter == "world_bible"}>World bibles</option>
        <option value="campaign" selected={@filter == "campaign"}>Campaigns</option>
      </select>
      <input type="text" name="q" value={@query} placeholder="Search by name…" style="flex:1;" phx-debounce="200" />
    </form>

    <div :if={@entries != [] and @shown == []} class="list-empty">No matching items. Try a different type or search.</div>

    <div :for={e <- @shown} class="card">
      <div class="row">
        <div>
          <h3><%= entry_name(e) %> <span class="faint">· <%= e.kind %></span></h3>
          <.visibility_badge visibility={e.visibility} />
          <span :if={e.frozen} class="badge">published snapshot</span>
        </div>
        <div class="spacer"></div>
        <a :if={e.kind == "character"} class="btn ghost sm" href={~p"/authoring/character/#{e.id}"}>Edit</a>
        <a :if={e.kind == "world_bible"} class="btn ghost sm" href={~p"/authoring/bible/#{e.id}"}>Edit</a>
        <a :if={e.kind == "campaign"} class="btn ghost sm" href={~p"/campaigns/#{e.id}"}>Open</a>
      </div>

      <div class="row" style="margin-top:.5rem;gap:.4rem;">
        <form id={"vis-#{e.id}"} phx-change="visibility">
          <input type="hidden" name="eid" value={e.id} />
          <select name="visibility" style="width:auto;">
            <option value="private" selected={e.visibility == "private"}>Private</option>
            <option value="unlisted" selected={e.visibility == "unlisted"}>Unlisted</option>
            <option value="public" selected={e.visibility == "public"}>Public</option>
          </select>
        </form>
        <span :if={e.visibility == "unlisted" and e.share_token} class="faint">
          share: <a href={~p"/s/#{e.share_token}"}>/s/<%= String.slice(e.share_token, 0, 8) %>…</a>
        </span>
        <div class="spacer"></div>
        <button class="btn ghost sm" phx-click="archive" phx-value-id={e.id}>Archive</button>
        <button class="btn danger sm" phx-click="delete" phx-value-id={e.id}
          data-confirm="Delete this? It's recoverable for a while.">Delete</button>
      </div>
    </div>
    """
  end

  defp entry_name(e) do
    case Library.payload(e) do
      %{name: n} when is_binary(n) -> n
      _ -> "Untitled"
    end
  end
end
