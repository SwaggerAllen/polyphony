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

    cast =
      Enum.filter(owned_chars, fn c ->
        n = char_name(c)
        n in (payload[:character_ids] || [])
      end)

    assign(socket,
      payload: payload,
      owner: owner,
      cast: cast,
      scenes: payload[:scenes] || [],
      bibles: bibles,
      bible_id: payload[:bible_id],
      bible_name: bible_label(bibles, payload[:bible_id])
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

  def handle_event("start_scene", _params, socket) do
    safe(socket, fn ->
      %{entry: entry, payload: payload, cast: cast} = socket.assigns
      scene_id = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
      premise = payload[:premise] || ""

      :ok =
        App.dispatch(%OpenScene{
          scene_id: scene_id,
          campaign_id: entry.id,
          premise: premise,
          opened_beat: 0
        })

      for c <- cast do
        sheet = Library.payload(c)
        name = char_name(c)
        :ok = App.dispatch(%EnterCharacter{scene_id: scene_id, character_id: name, beat: 1})
        seed_context(scene_id, name, sheet, premise)
      end

      Library.update_payload(entry.id, %{payload | scenes: [scene_id | socket.assigns.scenes]})
      {:noreply, redirect(socket, to: ~p"/play/#{scene_id}")}
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
    <h1><%= @payload[:name] || "Campaign" %></h1>
    <p class="dim"><%= @payload[:premise] %></p>

    <div class="card">
      <div class="row">
        <h3>Cast</h3>
        <div class="spacer"></div>
        <button class="btn" phx-click="start_scene" disabled={@cast == []}>Start a scene</button>
        <button class="btn ghost" phx-click="publish" data-confirm="Publish a public snapshot? It exposes the omniscient story.">Publish</button>
      </div>
      <div :if={@cast == []} class="faint">No cast — add characters to this campaign from setup.</div>
      <ul>
        <li :for={c <- @cast}><%= char_name(c) %></li>
      </ul>
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
