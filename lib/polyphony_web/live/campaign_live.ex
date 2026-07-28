defmodule PolyphonyWeb.CampaignLive do
  @moduledoc """
  Campaign overview: the cast, the scenes, and the levers to start a scene or publish.
  Starting a scene opens the event-sourced stream, enters the cast, and seeds each
  character's frozen context so the Director loop can run.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Library, Owner, Context, App}
  alias Polyphony.Context.Store
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Authoring.CharacterSheet

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "campaign" do
      {:ok, socket |> assign(page_title: "Campaign", entry: entry) |> load()}
    else
      {:ok, socket |> put_flash(:error, "Campaign not found.") |> redirect(to: ~p"/library")}
    end
  end

  defp load(socket) do
    payload = Library.payload(socket.assigns.entry)
    owner = Owner.of(socket.assigns.current_user)
    owned = Library.list_for_owner(owner)
    owned_chars = Enum.filter(owned, &(&1.kind == "character"))
    bibles = Enum.filter(owned, &(&1.kind == "world_bible"))

    # bible_id may be stored as a string (setup) or integer (select_world); normalize
    # so it matches integer entry ids for selection and the world roster filter.
    world_id = normalize_id(payload[:bible_id])

    # The cast references characters by their stable library id — never by name, so a
    # rename can't drop anyone. Names are resolved for display only.
    cast_ids = cast_ids(payload)
    cast = Enum.filter(owned_chars, &(&1.id in cast_ids))

    # Characters that can still be added: owned, not already cast, and — when a world
    # is attached — belonging to that world (or unassigned), so the world scopes the
    # roster the way the library filter does.
    addable =
      owned_chars
      |> Enum.reject(&(&1.id in cast_ids))
      |> Enum.filter(&addable_in_world?(&1, world_id))

    assign(socket,
      payload: payload,
      owner: owner,
      cast: cast,
      addable: addable,
      scenes: payload[:scenes] || [],
      bibles: bibles,
      bible_id: world_id,
      bible_name: bible_label(bibles, world_id)
    )
  end

  def handle_event("select_world", %{"bible_id" => id}, socket) do
    safe(socket, fn ->
      bible_id = if id == "", do: nil, else: String.to_integer(id)
      payload = Map.put(socket.assigns.payload, :bible_id, bible_id)
      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)

      {:noreply, socket |> assign(entry: entry) |> load() |> put_flash(:info, "World updated.")}
    end)
  end

  def handle_event("add_character", %{"id" => id}, socket) do
    safe(socket, fn ->
      case normalize_id(id) do
        nil ->
          {:noreply, socket}

        cid ->
          ids = Enum.uniq(cast_ids(socket.assigns.payload) ++ [cid])
          {:noreply, update_cast(socket, ids, "Added #{display_name(cid)} to the cast.")}
      end
    end)
  end

  def handle_event("remove_character", %{"id" => id}, socket) do
    safe(socket, fn ->
      cid = normalize_id(id)
      ids = Enum.reject(cast_ids(socket.assigns.payload), &(&1 == cid))
      {:noreply, update_cast(socket, ids, "Removed #{display_name(cid)} from the cast.")}
    end)
  end

  def handle_event("update_details", params, socket) do
    safe(socket, fn ->
      payload =
        socket.assigns.payload
        |> Map.put(:name, params["name"] || "")
        |> Map.put(:premise, params["premise"] || "")

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)
      {:noreply, socket |> assign(entry: entry) |> load()}
    end)
  end

  def handle_event("start_scene", _params, socket) do
    safe(socket, fn ->
      %{entry: entry, payload: payload, cast: cast} = socket.assigns
      # Only finalized characters enter the scene; pending stubs are skipped (they
      # aren't castable until generated — bulk-generate them from the library first).
      {ready, pending} = Enum.split_with(cast, &full?/1)

      if ready == [] do
        {:noreply,
         put_flash(socket, :error, "No ready characters — generate the pending ones first.")}
      else
        scene_id = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
        premise = payload[:premise] || ""

        :ok =
          App.dispatch(%OpenScene{
            scene_id: scene_id,
            campaign_id: entry.id,
            premise: premise,
            opened_beat: 0
          })

        for c <- ready do
          sheet = Library.payload(c)
          name = char_name(c)
          :ok = App.dispatch(%EnterCharacter{scene_id: scene_id, character_id: name, beat: 1})
          seed_context(scene_id, name, sheet, premise)
        end

        Library.update_payload(entry.id, %{payload | scenes: [scene_id | socket.assigns.scenes]})

        {:noreply, socket |> maybe_flash_pending(pending) |> redirect(to: ~p"/play/#{scene_id}")}
      end
    end)
  end

  def handle_event("publish", _params, socket) do
    safe(socket, fn ->
      %{entry: entry, payload: payload, cast: cast, owner: owner} = socket.assigns
      bible = if payload[:bible_id], do: Library.get(payload[:bible_id]) |> maybe_payload()

      characters =
        Enum.map(cast, fn c ->
          %{source_id: c.id, source_version: c.version, sheet: Library.payload(c)}
        end)

      Library.publish_campaign(
        %{
          owner: owner,
          campaign_id: entry.id,
          published_beat: 0,
          bible: bible,
          characters: characters,
          arc: []
        },
        visibility: "public"
      )

      {:noreply, put_flash(socket, :info, "Published a public snapshot of this campaign.")}
    end)
  end

  defp seed_context(scene_id, name, %CharacterSheet{} = sheet, premise) do
    ctx =
      Context.materialize(scene_id: scene_id, character_id: name, sheet: sheet, premise: premise)

    Store.put(scene_id, name, ctx)
  end

  defp seed_context(_scene_id, _name, _other, _premise), do: :ok

  defp maybe_payload(nil), do: nil
  defp maybe_payload(entry), do: Library.payload(entry)

  def render(assigns) do
    ~H"""
    <h1><%= if @payload[:name] in [nil, ""], do: "Untitled campaign", else: @payload[:name] %></h1>

    <div class="card">
      <form id="campaign-details" phx-change="update_details">
        <label class="gen-label"><span>Name</span></label>
        <input type="text" name="name" value={@payload[:name]} placeholder="Name this campaign…" phx-debounce="blur" />
        <label>Premise <span class="faint">(what the story is about)</span></label>
        <textarea name="premise" phx-debounce="blur"><%= @payload[:premise] %></textarea>
      </form>
    </div>

    <div class="card">
      <div class="row">
        <h3>Cast</h3>
        <div class="spacer"></div>
        <button class="btn" phx-click="start_scene" disabled={@cast == []}>Start a scene</button>
        <button class="btn ghost" phx-click="publish" data-confirm="Publish a public snapshot? It exposes the omniscient story.">Publish</button>
      </div>
      <div :if={@cast == []} class="faint">No cast yet — add characters below.</div>
      <ul class="rel-list">
        <li :for={c <- @cast} class="row rel-item">
          <span><%= char_name(c) %></span>
          <span :if={pending?(c)} class="badge stub">pending</span>
          <span class="spacer"></span>
          <button class="btn danger sm" phx-click="remove_character" phx-value-id={c.id}>Remove</button>
        </li>
      </ul>

      <form :if={@addable != []} id="add-character" phx-submit="add_character" class="row rel-add">
        <select name="id" style="flex:1;">
          <option :for={c <- @addable} value={c.id}><%= char_name(c) %><%= if pending?(c), do: " (pending)", else: "" %></option>
        </select>
        <button class="btn" type="submit">Add to cast</button>
      </form>
      <p :if={@addable == [] and @cast != []} class="faint">
        Every one of your characters<span :if={@bible_name}> in <%= @bible_name %></span> is already in the cast.
      </p>
      <p :if={@addable == [] and @cast == []} class="faint">
        No characters available<span :if={@bible_name}> for <%= @bible_name %></span> —
        create one in the <a href={~p"/library"}>Library</a><span :if={@bible_name}> and attach it to this world</span>.
      </p>
    </div>

    <div class="card">
      <div class="row">
        <h3>World</h3>
        <div class="spacer"></div>
        <span class="faint"><%= @bible_name || "no world attached" %></span>
      </div>
      <p class="dim">The world bible grounds the setting for this campaign's scenes and its published snapshot.</p>
      <form id="campaign-world" phx-change="select_world">
        <select name="bible_id" style="width:auto;">
          <option value="">— none —</option>
          <option :for={b <- @bibles} value={b.id} selected={@bible_id == b.id}><%= bible_label_of(b) %></option>
        </select>
      </form>
      <p :if={@bibles == []} class="faint">
        No world bibles yet — create one in the <a href={~p"/library"}>Library</a>.
      </p>
    </div>

    <div class="card">
      <h3>Scenes</h3>
      <div :if={@scenes == []} class="faint">No scenes yet. Start one above.</div>
      <ul>
        <li :for={s <- @scenes}><a href={~p"/play/#{s}"}>Scene <%= String.slice(s, 0, 12) %></a></li>
      </ul>
    </div>
    """
  end

  defp char_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "char-#{entry.id}"
    end
  end

  defp update_cast(socket, ids, flash) do
    payload = Map.put(socket.assigns.payload, :character_ids, ids)
    {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)
    socket |> assign(entry: entry) |> load() |> put_flash(:info, flash)
  end

  # The cast as a list of integer library ids (tolerating any legacy name entries,
  # which simply won't resolve to a character and drop out).
  defp cast_ids(payload) do
    (payload[:character_ids] || []) |> Enum.map(&normalize_id/1) |> Enum.reject(&is_nil/1)
  end

  defp display_name(nil), do: "character"

  defp display_name(id) do
    case Library.get(id) do
      nil -> "character"
      entry -> char_name(entry)
    end
  end

  defp full?(entry), do: match?(%CharacterSheet{status: :full}, Library.payload(entry))

  defp maybe_flash_pending(socket, []), do: socket

  defp maybe_flash_pending(socket, pending),
    do:
      put_flash(
        socket,
        :info,
        "Skipped #{length(pending)} pending character(s) — generate them, then re-add to a scene."
      )

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  # With no world attached, every owned character is addable; with one attached, the
  # roster is scoped to that world's characters plus any not yet assigned to a world.
  defp addable_in_world?(_char, nil), do: true

  defp addable_in_world?(char, world_id) do
    wid = char |> Library.payload() |> Map.get(:world_bible_id)
    wid in [nil, world_id]
  end

  defp pending?(char) do
    match?(%CharacterSheet{status: s} when s != :full, Library.payload(char))
  end

  defp bible_label(_bibles, nil), do: nil

  defp bible_label(bibles, id) do
    case Enum.find(bibles, &(&1.id == id)) do
      nil -> nil
      entry -> bible_label_of(entry)
    end
  end

  defp bible_label_of(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled world (##{entry.id})"
    end
  end
end
