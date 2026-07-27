defmodule PolyphonyWeb.SheetEditorLive do
  @moduledoc "V4 (sheet editor): edit a character's authored sheet; promote a stub (§B8)."
  use PolyphonyWeb, :live_view

  alias Polyphony.Library
  alias Polyphony.Authoring.{CharacterSheet, Stub}

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "character" do
      {:ok,
       assign(socket, page_title: "Edit character", entry: entry, sheet: Library.payload(entry))}
    else
      {:ok, socket |> put_flash(:error, "Character not found.") |> redirect(to: ~p"/library")}
    end
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      sheet = %CharacterSheet{
        socket.assigns.sheet
        | name: params["name"],
          premise: params["premise"],
          appearance: params["appearance"],
          voice: params["voice"],
          temperament: params["temperament"],
          backstory: params["backstory"]
      }

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, sheet)
      {:noreply, socket |> put_flash(:info, "Saved.") |> assign(entry: entry, sheet: sheet)}
    end)
  end

  def handle_event("promote", _params, socket) do
    safe(socket, fn ->
      case Stub.promote(socket.assigns.sheet) do
        {:ok, promoted} ->
          {:ok, entry} = Library.update_payload(socket.assigns.entry.id, promoted)

          {:noreply,
           socket
           |> put_flash(:info, "Promoted — review and accept below.")
           |> assign(entry: entry, sheet: promoted)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not generate a sheet.")}
      end
    end)
  end

  def handle_event("accept", _params, socket) do
    safe(socket, fn ->
      accepted = Stub.accept(socket.assigns.sheet)
      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, accepted)

      {:noreply,
       socket
       |> put_flash(:info, "Accepted — the character is ready to cast.")
       |> assign(entry: entry, sheet: accepted)}
    end)
  end

  def render(assigns) do
    ~H"""
    <div class="row">
      <h1>Edit character</h1>
      <div class="spacer"></div>
      <span :if={@sheet.status == :stub} class="badge stub">stub</span>
      <span :if={@sheet.status == :proposed} class="badge">proposed — review</span>
    </div>

    <div :if={@sheet.status == :stub} class="card">
      <p class="dim">This is a stub (name + role). Promote it to generate a full sheet behind a review gate.</p>
      <button class="btn" phx-click="promote">Promote to full sheet</button>
    </div>
    <div :if={@sheet.status == :proposed} class="card">
      <p class="dim">Generated draft below. Accept to make it usable.</p>
      <button class="btn" phx-click="accept">Accept</button>
    </div>

    <div class="card">
      <form phx-submit="save">
        <label>Name</label>
        <input type="text" name="name" value={@sheet.name} />
        <label>Premise</label>
        <textarea name="premise"><%= @sheet.premise %></textarea>
        <label>Appearance</label>
        <textarea name="appearance"><%= @sheet.appearance %></textarea>
        <label>Voice</label>
        <input type="text" name="voice" value={@sheet.voice} />
        <label>Temperament</label>
        <input type="text" name="temperament" value={@sheet.temperament} />
        <label>Backstory</label>
        <textarea name="backstory"><%= @sheet.backstory %></textarea>
        <br /><br />
        <button class="btn" type="submit">Save</button>
        <a class="btn ghost" href={~p"/library"}>Back to library</a>
      </form>
    </div>
    """
  end
end
