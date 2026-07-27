defmodule PolyphonyWeb.BibleEditorLive do
  @moduledoc "V6 (world bible editor): setting, tone, rules, and starting canon."
  use PolyphonyWeb, :live_view

  alias Polyphony.Library
  alias Polyphony.Authoring.WorldBible

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "world_bible" do
      {:ok,
       assign(socket, page_title: "Edit world bible", entry: entry, bible: Library.payload(entry))}
    else
      {:ok, socket |> put_flash(:error, "World bible not found.") |> redirect(to: ~p"/library")}
    end
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      bible = %WorldBible{
        socket.assigns.bible
        | name: params["name"],
          setting: params["setting"],
          tone: params["tone"],
          rules: lines(params["rules"]),
          starting_canon: lines(params["starting_canon"])
      }

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, bible)
      {:noreply, socket |> put_flash(:info, "Saved.") |> assign(entry: entry, bible: bible)}
    end)
  end

  defp lines(nil), do: []

  defp lines(text),
    do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  def render(assigns) do
    ~H"""
    <h1>World bible</h1>
    <div class="card">
      <form phx-submit="save">
        <label>Name</label>
        <input type="text" name="name" value={@bible.name} />
        <label>Setting</label>
        <textarea name="setting"><%= @bible.setting %></textarea>
        <label>Tone</label>
        <input type="text" name="tone" value={@bible.tone} />
        <label>Rules / physics <span class="faint">(one per line)</span></label>
        <textarea name="rules"><%= Enum.join(@bible.rules || [], "\n") %></textarea>
        <label>Starting canon <span class="faint">(one per line)</span></label>
        <textarea name="starting_canon"><%= Enum.join(@bible.starting_canon || [], "\n") %></textarea>
        <br /><br />
        <button class="btn" type="submit">Save</button>
        <a class="btn ghost" href={~p"/library"}>Back to library</a>
      </form>
    </div>
    """
  end
end
