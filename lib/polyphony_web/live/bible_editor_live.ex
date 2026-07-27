defmodule PolyphonyWeb.BibleEditorLive do
  @moduledoc """
  V6 (world bible editor): setting, tone, rules, and starting canon — with
  auto-generation (`Polyphony.Authoring.Autofill`), whole-form from a free-text
  brief or one field at a time from the others. Generation only populates the form;
  the author reviews and Saves.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.Library
  alias Polyphony.Authoring.WorldBible
  alias PolyphonyWeb.AutofillControls

  @fields ~w(name setting tone rules starting_canon)

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "world_bible" do
      bible = Library.payload(entry)

      {:ok,
       assign(socket,
         page_title: "Edit world bible",
         entry: entry,
         bible: bible,
         draft: draft_from_bible(bible),
         generating: MapSet.new()
       )}
    else
      {:ok, socket |> put_flash(:error, "World bible not found.") |> redirect(to: ~p"/library")}
    end
  end

  def handle_event("draft_changed", params, socket) do
    {:noreply, assign(socket, :draft, Map.merge(socket.assigns.draft, Map.take(params, @fields)))}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      d = Map.merge(socket.assigns.draft, Map.take(params, @fields))

      bible = %WorldBible{
        socket.assigns.bible
        | name: d["name"],
          setting: d["setting"],
          tone: d["tone"],
          rules: lines(d["rules"]),
          starting_canon: lines(d["starting_canon"])
      }

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, bible)

      {:noreply,
       socket
       |> put_flash(:info, "Saved.")
       |> assign(entry: entry, bible: bible, draft: draft_from_bible(bible))}
    end)
  end

  def handle_event("generate_all", %{"brief" => brief}, socket) do
    safe(socket, fn -> {:noreply, AutofillControls.start_all(socket, :world_bible, brief)} end)
  end

  def handle_event("generate_field", %{"field" => field}, socket) when field in @fields do
    safe(socket, fn -> {:noreply, AutofillControls.start_field(socket, :world_bible, field)} end)
  end

  def handle_async(:autofill_all, {:ok, result}, socket),
    do: {:noreply, AutofillControls.resolve_all(socket, result)}

  def handle_async(:autofill_all, {:exit, reason}, socket),
    do: {:noreply, AutofillControls.resolve_all(socket, {:exit, reason})}

  def handle_async({:autofill_field, field}, {:ok, result}, socket),
    do: {:noreply, AutofillControls.resolve_field(socket, field, result)}

  def handle_async({:autofill_field, field}, {:exit, reason}, socket),
    do: {:noreply, AutofillControls.resolve_field(socket, field, {:exit, reason})}

  defp draft_from_bible(bible) do
    %{
      "name" => bible.name || "",
      "setting" => bible.setting || "",
      "tone" => bible.tone || "",
      "rules" => Enum.join(bible.rules || [], "\n"),
      "starting_canon" => Enum.join(bible.starting_canon || [], "\n")
    }
  end

  defp lines(nil), do: []

  defp lines(text),
    do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, default: nil)
  attr(:generating, :any, required: true)

  defp field_label(assigns) do
    ~H"""
    <label class="row gen-label">
      <span><%= @label %> <span :if={@hint} class="faint"><%= @hint %></span></span>
      <span class="spacer"></span>
      <button
        type="button"
        class="btn sm ghost gen-btn"
        phx-click="generate_field"
        phx-value-field={@field}
        disabled={AutofillControls.generating?(@generating, @field)}
        title={"Generate #{@label} from the other fields"}
      >
        <%= if AutofillControls.generating?(@generating, @field), do: "✨ …", else: "✨ Generate" %>
      </button>
    </label>
    """
  end

  def render(assigns) do
    ~H"""
    <h1>World bible</h1>

    <div class="card gen-brief">
      <form phx-submit="generate_all">
        <label>Describe the world — we'll fill in every field <span class="faint">(builds on anything you've already written)</span></label>
        <textarea
          name="brief"
          rows="2"
          placeholder="e.g. A rain-soaked cyberpunk port city where memory can be bought, sold, and forged."
        ></textarea>
        <button class="btn" type="submit" disabled={AutofillControls.generating?(@generating, "all")}>
          <%= if AutofillControls.generating?(@generating, "all"), do: "✨ Generating…", else: "✨ Generate all fields" %>
        </button>
      </form>
    </div>

    <div class="card">
      <form id="bible-form" phx-submit="save" phx-change="draft_changed">
        <.field_label field="name" label="Name" generating={@generating} />
        <input type="text" name="name" value={@draft["name"]} />
        <.field_label field="setting" label="Setting" generating={@generating} />
        <textarea name="setting"><%= @draft["setting"] %></textarea>
        <.field_label field="tone" label="Tone" generating={@generating} />
        <input type="text" name="tone" value={@draft["tone"]} />
        <.field_label field="rules" label="Rules / physics" hint="(one per line)" generating={@generating} />
        <textarea name="rules"><%= @draft["rules"] %></textarea>
        <.field_label
          field="starting_canon"
          label="Starting canon"
          hint="(one per line)"
          generating={@generating}
        />
        <textarea name="starting_canon"><%= @draft["starting_canon"] %></textarea>
        <br /><br />
        <button class="btn" type="submit">Save</button>
        <a class="btn ghost" href={~p"/library"}>Back to library</a>
      </form>
    </div>
    """
  end
end
