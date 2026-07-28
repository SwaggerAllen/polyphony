defmodule PolyphonyWeb.LibraryLive do
  @moduledoc """
  V9 (library): the owner's authored entities, **grouped by world**. Each world bible
  is a section; its characters and campaigns nest beneath it, with unassigned items in
  a trailing "No world" group — so navigation follows the setting rather than one flat
  list. A type filter and a name search narrow what's shown. Everything is scoped
  through `Polyphony.Owner` (the §P2 indirection) — the view never speaks a raw user id.

  Creating an artifact makes a blank entry and jumps straight to its editor, where the
  name is typed or generated — no name is required up front.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, StubGen, WorldBible}

  require Logger

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Library", filter: "all", query: "", generating: false)
     |> load()}
  end

  defp load(socket) do
    owner = Owner.of(socket.assigns.current_user)
    entries = Library.list_for_owner(owner)

    socket
    |> assign(owner: owner, entries: entries, pending_count: Enum.count(entries, &pending?/1))
    |> assign_groups()
  end

  # Group the shown entries under their world. A world group appears when it has any
  # visible member, or (for the "all"/"world bibles" filters) when the world itself
  # matches the search. Characters/campaigns with no world land in a trailing group.
  defp assign_groups(socket) do
    %{entries: entries, filter: filter, query: query} = socket.assigns
    q = query |> to_string() |> String.trim() |> String.downcase()

    worlds =
      entries
      |> Enum.filter(&(&1.kind == "world_bible"))
      |> Enum.sort_by(&String.downcase(entry_name(&1)))

    members = Enum.filter(entries, &(&1.kind in ["character", "campaign"]))
    by_world = Enum.group_by(members, &member_world_id/1)

    world_groups =
      for world <- worlds,
          group = build_group(world, Map.get(by_world, world.id, []), filter, q),
          group != nil,
          do: group

    none_members = visible_members(Map.get(by_world, :none, []), filter, q, false)
    none_group = if none_members == [], do: [], else: [%{world: nil, members: none_members}]

    assign(socket, groups: world_groups ++ none_group)
  end

  defp build_group(world, members, filter, q) do
    world_matches = q == "" or String.contains?(String.downcase(entry_name(world)), q)
    visible = visible_members(members, filter, q, world_matches)

    cond do
      visible != [] -> %{world: world, members: visible}
      show_kind?(filter, "world_bible") and world_matches -> %{world: world, members: []}
      true -> nil
    end
  end

  defp visible_members(members, filter, q, world_matches) do
    members
    |> Enum.filter(fn m ->
      show_kind?(filter, m.kind) and
        (q == "" or world_matches or String.contains?(String.downcase(entry_name(m)), q))
    end)
    |> Enum.sort_by(&{&1.kind, String.downcase(entry_name(&1))})
  end

  defp show_kind?("all", _kind), do: true
  defp show_kind?(filter, kind), do: filter == kind

  # Which world an entry belongs to: a character via `world_bible_id`, a campaign via
  # `bible_id` (which may be a string), else `:none`.
  defp member_world_id(entry) do
    payload = Library.payload(entry)

    case normalize_id(Map.get(payload, :world_bible_id) || Map.get(payload, :bible_id)) do
      nil -> :none
      id -> id
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  # ── Events ──────────────────────────────────────────────────────────────────────

  # Create a blank artifact and jump to its editor — the name is set (or generated)
  # there. No name is required to begin.
  def handle_event("new", %{"kind" => kind}, socket)
      when kind in ~w(character world_bible campaign) do
    safe(socket, fn ->
      entry =
        Library.put(%{owner: socket.assigns.owner, kind: kind, payload: blank_payload(kind)})

      {:noreply, push_navigate(socket, to: editor_path(kind, entry.id))}
    end)
  end

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(filter: params["kind"] || "all", query: params["q"] || "")
     |> assign_groups()}
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

  # Bulk-generate every pending stub — fill each one's sheet (grounded in its world
  # and role) and finalize it, so the author doesn't open them one by one. Runs async
  # with a busy button; each stub is best-effort.
  def handle_event("generate_pending", _params, socket) do
    safe(socket, fn ->
      case Enum.filter(socket.assigns.entries, &pending?/1) do
        [] ->
          {:noreply, socket}

        stubs ->
          user = socket.assigns.current_user

          {:noreply,
           socket
           |> assign(generating: true)
           |> start_async(:generate_pending, fn -> generate_stubs(stubs, user) end)}
      end
    end)
  end

  def handle_async(:generate_pending, {:ok, {done, failed}}, socket) do
    detail = if failed > 0, do: " #{failed} failed — open those to retry.", else: ""

    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:info, "Generated #{done} character(s).#{detail}")
     |> load()}
  end

  def handle_async(:generate_pending, result, socket) do
    Logger.warning("[authoring] bulk stub generation failed: #{inspect(result)}")

    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:error, "Bulk generation failed — try again.")
     |> load()}
  end

  defp blank_payload("character"), do: %CharacterSheet{name: "", status: :full}
  defp blank_payload("world_bible"), do: %WorldBible{name: ""}

  defp blank_payload("campaign"),
    do: %{kind: :campaign, name: "", premise: "", character_ids: [], bible_id: nil, scenes: []}

  defp editor_path("character", id), do: ~p"/authoring/character/#{id}"
  defp editor_path("world_bible", id), do: ~p"/authoring/bible/#{id}"
  defp editor_path("campaign", id), do: ~p"/campaigns/#{id}"

  # ── Bulk stub generation ─────────────────────────────────────────────────────

  defp generate_stubs(stubs, user) do
    uid = user && user.id

    Enum.reduce(stubs, {0, 0}, fn entry, {ok, bad} ->
      case StubGen.finalize(entry, uid) do
        :ok -> {ok + 1, bad}
        :error -> {ok, bad + 1}
      end
    end)
  end

  # ── Render ─────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <h1>Your library</h1>

    <div class="card">
      <form id="library-new" phx-submit="new" class="row">
        <select name="kind" style="width:auto;">
          <option value="character">New character</option>
          <option value="world_bible">New world bible</option>
          <option value="campaign">New campaign</option>
        </select>
        <button class="btn" type="submit">Create</button>
        <span class="faint">— opens the editor, where you name it.</span>
      </form>
    </div>

    <div :if={@entries == []} class="list-empty">Nothing here yet. Create a character, world, or campaign to begin.</div>

    <form :if={@entries != []} id="library-filter" phx-change="filter" class="row library-filter">
      <select name="kind" style="width:auto;">
        <option value="all" selected={@filter == "all"}>All types</option>
        <option value="character" selected={@filter == "character"}>Characters</option>
        <option value="world_bible" selected={@filter == "world_bible"}>World bibles</option>
        <option value="campaign" selected={@filter == "campaign"}>Campaigns</option>
      </select>
      <input type="text" name="q" value={@query} placeholder="Search by name…" style="flex:1;" phx-debounce="200" />
    </form>

    <div :if={@pending_count > 0} class="card pending-banner">
      <div class="row">
        <span>
          <strong><%= @pending_count %></strong> pending character<%= if @pending_count == 1, do: "", else: "s" %>
          <span class="faint">— stubs from relationships, not yet fleshed out.</span>
        </span>
        <div class="spacer"></div>
        <button class="btn" phx-click="generate_pending" disabled={@generating}>
          <%= if @generating, do: "✨ Generating…", else: "✨ Generate all pending" %>
        </button>
      </div>
    </div>

    <div :if={@entries != [] and @groups == []} class="list-empty">No matching items. Try a different type or search.</div>

    <div :for={g <- @groups} class="card world-group">
      <div :if={g.world} class="row group-head">
        <h3><%= entry_name(g.world) %> <span class="faint">· world</span></h3>
        <.visibility_badge visibility={g.world.visibility} />
        <div class="spacer"></div>
        <.entry_controls entry={g.world} />
      </div>
      <div :if={is_nil(g.world)} class="row group-head">
        <h3 class="faint">No world</h3>
      </div>

      <div :if={g.members == []} class="faint member-empty">Nothing in this world yet.</div>
      <ul class="member-list">
        <li :for={m <- g.members} class="row member">
          <span><%= entry_name(m) %> <span class="faint">· <%= m.kind %></span></span>
          <span :if={pending?(m)} class="badge stub">pending</span>
          <.visibility_badge visibility={m.visibility} />
          <div class="spacer"></div>
          <.entry_controls entry={m} />
        </li>
      </ul>
    </div>
    """
  end

  # The per-entry controls: visibility select, share link (unlisted), edit/open, and
  # archive/delete — shared by world headers and their nested members.
  attr(:entry, :map, required: true)

  defp entry_controls(assigns) do
    ~H"""
    <form id={"vis-#{@entry.id}"} phx-change="visibility" style="display:inline;">
      <input type="hidden" name="eid" value={@entry.id} />
      <select name="visibility" style="width:auto;">
        <option value="private" selected={@entry.visibility == "private"}>Private</option>
        <option value="unlisted" selected={@entry.visibility == "unlisted"}>Unlisted</option>
        <option value="public" selected={@entry.visibility == "public"}>Public</option>
      </select>
    </form>
    <a :if={@entry.kind == "character"} class="btn ghost sm" href={~p"/authoring/character/#{@entry.id}"}>Edit</a>
    <a :if={@entry.kind == "world_bible"} class="btn ghost sm" href={~p"/authoring/bible/#{@entry.id}"}>Edit</a>
    <a :if={@entry.kind == "campaign"} class="btn ghost sm" href={~p"/campaigns/#{@entry.id}"}>Open</a>
    <button class="btn ghost sm" phx-click="archive" phx-value-id={@entry.id}>Archive</button>
    <button class="btn danger sm" phx-click="delete" phx-value-id={@entry.id}
      data-confirm="Delete this? It's recoverable for a while.">Delete</button>
    """
  end

  defp entry_name(e) do
    case Library.payload(e) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled"
    end
  end

  # A character stubbed from another's relationships is "pending" until finalized.
  defp pending?(%{kind: "character"} = e),
    do: match?(%{status: s} when s != :full, Library.payload(e))

  defp pending?(_), do: false
end
