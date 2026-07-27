defmodule PolyphonyWeb.SheetEditorLive do
  @moduledoc """
  V4 (sheet editor): edit a character's authored sheet; promote a stub (§B8); and
  auto-generate content (`Polyphony.Authoring.Autofill`) either whole-form from a
  free-text brief or one field at a time from the others. Generation only populates
  the form — the author reviews and Saves.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.Library
  alias Polyphony.Authoring.{CharacterSheet, Stub}
  alias PolyphonyWeb.AutofillControls

  @fields ~w(name premise appearance voice temperament backstory)

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "character" do
      sheet = Library.payload(entry)

      {:ok,
       assign(socket,
         page_title: "Edit character",
         entry: entry,
         sheet: sheet,
         draft: draft_from_sheet(sheet),
         generating: MapSet.new(),
         saved: false
       )}
    else
      {:ok, socket |> put_flash(:error, "Character not found.") |> redirect(to: ~p"/library")}
    end
  end

  def handle_event("draft_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:draft, Map.merge(socket.assigns.draft, Map.take(params, @fields)))
     |> assign(:saved, false)}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      d = Map.merge(socket.assigns.draft, Map.take(params, @fields))

      sheet = %CharacterSheet{
        socket.assigns.sheet
        | name: d["name"],
          premise: d["premise"],
          appearance: d["appearance"],
          voice: d["voice"],
          temperament: d["temperament"],
          backstory: d["backstory"]
      }

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, sheet)

      # Inline confirmation (see the Save button) rather than a top-of-page flash,
      # which is off-screen on mobile after a scroll down the form.
      {:noreply,
       assign(socket, entry: entry, sheet: sheet, draft: draft_from_sheet(sheet), saved: true)}
    end)
  end

  def handle_event("generate_all", %{"brief" => brief}, socket) do
    safe(socket, fn -> {:noreply, AutofillControls.start_all(socket, :character, brief)} end)
  end

  def handle_event("generate_field", %{"field" => field}, socket) when field in @fields do
    safe(socket, fn -> {:noreply, AutofillControls.start_field(socket, :character, field)} end)
  end

  def handle_event("promote", _params, socket) do
    safe(socket, fn ->
      case Stub.promote(socket.assigns.sheet) do
        {:ok, promoted} ->
          {:ok, entry} = Library.update_payload(socket.assigns.entry.id, promoted)

          {:noreply,
           socket
           |> put_flash(:info, "Promoted — review and accept below.")
           |> assign(
             entry: entry,
             sheet: promoted,
             draft: draft_from_sheet(promoted),
             saved: false
           )}

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
       |> assign(entry: entry, sheet: accepted, draft: draft_from_sheet(accepted), saved: false)}
    end)
  end

  def handle_async(:autofill_all, {:ok, result}, socket),
    do: {:noreply, socket |> AutofillControls.resolve_all(result) |> assign(:saved, false)}

  def handle_async(:autofill_all, {:exit, reason}, socket),
    do: {:noreply, AutofillControls.resolve_all(socket, {:exit, reason})}

  def handle_async({:autofill_field, field}, {:ok, result}, socket),
    do:
      {:noreply, socket |> AutofillControls.resolve_field(field, result) |> assign(:saved, false)}

  def handle_async({:autofill_field, field}, {:exit, reason}, socket),
    do: {:noreply, AutofillControls.resolve_field(socket, field, {:exit, reason})}

  defp draft_from_sheet(sheet) do
    %{
      "name" => sheet.name || "",
      "premise" => sheet.premise || "",
      "appearance" => sheet.appearance || "",
      "voice" => sheet.voice || "",
      "temperament" => sheet.temperament || "",
      "backstory" => sheet.backstory || ""
    }
  end

  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:generating, :any, required: true)

  defp field_label(assigns) do
    ~H"""
    <label class="row gen-label">
      <span><%= @label %></span>
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

    <div class="card gen-brief">
      <form phx-submit="generate_all">
        <label>Describe the character — we'll fill in every field <span class="faint">(builds on anything you've already written)</span></label>
        <textarea
          name="brief"
          rows="2"
          placeholder="e.g. A jaded harbor-town detective who used to be a priest and still prays out of habit."
        ></textarea>
        <button class="btn" type="submit" disabled={AutofillControls.generating?(@generating, "all")}>
          <%= if AutofillControls.generating?(@generating, "all"), do: "✨ Generating…", else: "✨ Generate all fields" %>
        </button>
      </form>
    </div>

    <div class="card">
      <form id="sheet-form" phx-submit="save" phx-change="draft_changed">
        <.field_label field="name" label="Name" generating={@generating} />
        <input type="text" name="name" value={@draft["name"]} />
        <.field_label field="premise" label="Premise" generating={@generating} />
        <textarea name="premise"><%= @draft["premise"] %></textarea>
        <.field_label field="appearance" label="Appearance" generating={@generating} />
        <textarea name="appearance"><%= @draft["appearance"] %></textarea>
        <.field_label field="voice" label="Voice" generating={@generating} />
        <input type="text" name="voice" value={@draft["voice"]} />
        <.field_label field="temperament" label="Temperament" generating={@generating} />
        <input type="text" name="temperament" value={@draft["temperament"]} />
        <.field_label field="backstory" label="Backstory" generating={@generating} />
        <textarea name="backstory"><%= @draft["backstory"] %></textarea>
        <br /><br />
        <div class="row save-row">
          <button class="btn" type="submit">Save</button>
          <span :if={@saved} class="saved-note" role="status">✓ Saved</span>
          <span class="spacer"></span>
          <a class="btn ghost" href={~p"/library"}>Back to library</a>
        </div>
      </form>
    </div>
    """
  end
end
