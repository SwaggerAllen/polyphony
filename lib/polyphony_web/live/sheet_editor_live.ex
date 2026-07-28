defmodule PolyphonyWeb.SheetEditorLive do
  @moduledoc """
  V4 (sheet editor): edit a character's authored sheet; promote a stub (§B8); and
  auto-generate content (`Polyphony.Authoring.Autofill`) either whole-form from a
  free-text brief or one field at a time from the others. Generation only populates
  the form — the author reviews and Saves.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Relationship
  alias PolyphonyWeb.AutofillControls

  @fields ~w(name premise appearance voice temperament backstory)

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "character" do
      # struct/2 fills any field the stored struct predates (e.g. world_bible_id),
      # so older saved sheets load without a KeyError.
      sheet = struct(CharacterSheet, Map.from_struct(Library.payload(entry)))
      worlds = load_worlds(socket.assigns.current_user)
      world_id = if sheet.world_bible_id, do: to_string(sheet.world_bible_id), else: ""

      {:ok,
       assign(socket,
         page_title: "Edit character",
         entry: entry,
         sheet: sheet,
         draft: draft_from_sheet(sheet),
         generating: MapSet.new(),
         saved: false,
         world_entries: worlds,
         worlds: world_options(worlds),
         world_id: world_id,
         world_context: world_context_for(worlds, world_id),
         relationships: sheet.relationships || [],
         char_names: other_character_names(socket.assigns.current_user, entry.id),
         relations_context:
           relations_context(sheet.relationships || [], socket.assigns.current_user, entry.id)
       )}
    else
      {:ok, socket |> put_flash(:error, "Character not found.") |> redirect(to: ~p"/library")}
    end
  end

  def handle_event("select_world", %{"world_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(world_id: id, world_context: world_context_for(socket.assigns.world_entries, id))
     |> assign(:saved, false)}
  end

  def handle_event("draft_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:draft, Map.merge(socket.assigns.draft, Map.take(params, @fields)))
     |> assign(:saved, false)}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      %{current_user: user, entry: %{id: id}} = socket.assigns
      d = Map.merge(socket.assigns.draft, Map.take(params, @fields))
      rels = socket.assigns.relationships

      # Any relationship target that isn't an existing character becomes a stub, so
      # you can seed a web of connections before every character is authored.
      existing = other_character_names(user, id)
      stubbed = seed_stubs(rels, existing, d["name"], Owner.of(user))

      sheet = %CharacterSheet{
        socket.assigns.sheet
        | name: d["name"],
          premise: d["premise"],
          appearance: d["appearance"],
          voice: d["voice"],
          temperament: d["temperament"],
          backstory: d["backstory"],
          world_bible_id: world_id_int(socket.assigns.world_id),
          relationships: rels
      }

      {:ok, entry} = Library.update_payload(id, sheet)

      # Inline confirmation (see the Save button) rather than a top-of-page flash,
      # which is off-screen on mobile after a scroll down the form.
      socket =
        socket
        |> assign(
          entry: entry,
          sheet: sheet,
          draft: draft_from_sheet(sheet),
          char_names: other_character_names(user, id),
          saved: true
        )
        |> assign_relationships(rels)

      {:noreply, maybe_flash_stubs(socket, stubbed)}
    end)
  end

  def handle_event("add_relationship", %{"target" => target} = params, socket) do
    safe(socket, fn ->
      case String.trim(target) do
        "" ->
          {:noreply, put_flash(socket, :error, "Give the related character a name.")}

        name ->
          rel = %Relationship{target: name, descriptor: String.trim(params["descriptor"] || "")}

          {:noreply,
           socket
           |> assign_relationships(socket.assigns.relationships ++ [rel])
           |> assign(:saved, false)}
      end
    end)
  end

  def handle_event("remove_relationship", %{"index" => i}, socket) do
    idx = String.to_integer(i)

    {:noreply,
     socket
     |> assign_relationships(List.delete_at(socket.assigns.relationships, idx))
     |> assign(:saved, false)}
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

  defp world_id_int(""), do: nil
  defp world_id_int(nil), do: nil
  defp world_id_int(id) when is_binary(id), do: String.to_integer(id)

  # The owner's other characters' names (for the relationship datalist / the
  # existing-vs-stub decision) — excludes this character.
  defp other_character_names(user, exclude_id) do
    user
    |> Library.list_for_owner()
    |> Enum.filter(&(&1.kind == "character" and &1.id != exclude_id))
    |> Enum.map(&char_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp char_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  # Create a stub character for every relationship target that isn't already an
  # existing character (case-insensitive) or this character itself. Each stub records
  # the inbound relationship(s) that gave rise to it, seeding its later promotion.
  # Returns the names actually stubbed.
  defp seed_stubs(relationships, existing_names, self_name, owner) do
    existing = MapSet.new(existing_names, &String.downcase/1)
    self_down = String.downcase(self_name || "")

    relationships
    |> Enum.map(& &1.target)
    |> Enum.uniq()
    |> Enum.reject(fn t ->
      t == "" or String.downcase(t) == self_down or MapSet.member?(existing, String.downcase(t))
    end)
    |> Enum.map(fn target ->
      inbound =
        for r <- relationships,
            r.target == target,
            do: %Relationship{target: self_name, descriptor: r.descriptor}

      # Seed the stub's one-line role from the first non-empty descriptor that
      # introduced it, so it reads meaningfully in the library before promotion.
      role = inbound |> Enum.map(& &1.descriptor) |> Enum.find("", &(&1 not in [nil, ""]))

      Library.put(%{
        owner: owner,
        kind: "character",
        payload: Stub.new(target, role, relationships: inbound)
      })

      target
    end)
  end

  defp maybe_flash_stubs(socket, []), do: socket

  defp maybe_flash_stubs(socket, names),
    do: put_flash(socket, :info, "Stubbed new character(s): #{Enum.join(names, ", ")}.")

  # Keep the relationships list and the derived generation context (the related
  # characters' sheets) in lockstep, so a ✨ generate always sees the current web.
  defp assign_relationships(socket, relationships) do
    assign(socket,
      relationships: relationships,
      relations_context:
        relations_context(relationships, socket.assigns.current_user, socket.assigns.entry.id)
    )
  end

  # For each relationship whose target is an existing character, a compact snapshot
  # of that character's sheet + how this character regards them — the context that
  # makes generated backstory/voice fit the people they're connected to.
  defp relations_context(relationships, user, exclude_id) do
    by_name =
      user
      |> Library.list_for_owner()
      |> Enum.filter(&(&1.kind == "character" and &1.id != exclude_id))
      |> Map.new(fn e -> {String.downcase(char_name(e) || ""), e} end)

    for r <- relationships,
        entry = Map.get(by_name, String.downcase(r.target)),
        entry != nil do
      s = Library.payload(entry)

      %{
        "name" => r.target,
        "descriptor" => r.descriptor,
        "premise" => s.premise,
        "voice" => s.voice,
        "temperament" => s.temperament,
        "backstory" => s.backstory
      }
    end
  end

  defp load_worlds(user) do
    user |> Library.list_for_owner() |> Enum.filter(&(&1.kind == "world_bible"))
  end

  defp world_options(entries), do: for(e <- entries, do: {to_string(e.id), world_name(e)})

  defp world_name(entry) do
    case Library.payload(entry) do
      %WorldBible{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled world (##{entry.id})"
    end
  end

  # The selected world bible as display fields (or nil) — the seed for generation.
  defp world_context_for(_entries, id) when id in [nil, ""], do: nil

  defp world_context_for(entries, id) do
    case Enum.find(entries, &(to_string(&1.id) == id)) do
      nil ->
        nil

      entry ->
        wb = Library.payload(entry)

        %{
          "name" => wb.name || "",
          "setting" => wb.setting || "",
          "tone" => wb.tone || "",
          "rules" => Enum.join(wb.rules || [], "\n"),
          "starting_canon" => Enum.join(wb.starting_canon || [], "\n")
        }
    end
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
      <form id="world-select-form" phx-change="select_world">
        <label>World <span class="faint">(grounds generated backstory &amp; voice in a setting)</span></label>
        <select name="world_id">
          <option value="">— none —</option>
          <option :for={{id, name} <- @worlds} value={id} selected={@world_id == id}><%= name %></option>
        </select>
        <p :if={@worlds == []} class="faint">
          No world bibles yet — create one in the <a href={~p"/library"}>Library</a> to ground generation.
        </p>
      </form>

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
        <textarea name="voice"><%= @draft["voice"] %></textarea>
        <.field_label field="temperament" label="Temperament" generating={@generating} />
        <textarea name="temperament"><%= @draft["temperament"] %></textarea>
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

    <div class="card">
      <h3>Relationships</h3>
      <p class="dim">
        How this character regards others. Pick an existing character or type a new name —
        a new name becomes a <strong>stub</strong> character (flesh it out later), created when you Save.
      </p>

      <div :if={@relationships == []} class="faint">No relationships yet.</div>
      <ul class="rel-list">
        <li :for={{r, i} <- Enum.with_index(@relationships)} class="row rel-item">
          <span>→ <strong><%= r.target %></strong><span :if={r.descriptor not in [nil, ""]}> — <%= r.descriptor %></span></span>
          <span class="spacer"></span>
          <button
            type="button"
            class="btn danger sm"
            phx-click="remove_relationship"
            phx-value-index={i}
          >
            Remove
          </button>
        </li>
      </ul>

      <form id="rel-form" phx-submit="add_relationship" class="row rel-add">
        <input type="text" name="target" list="char-names" placeholder="Character name…" autocomplete="off" />
        <input
          type="text"
          name="descriptor"
          placeholder="how they regard them (e.g. estranged mentor)"
          style="flex:1;"
        />
        <button class="btn" type="submit">Add</button>
      </form>
      <datalist id="char-names">
        <option :for={n <- @char_names} value={n}></option>
      </datalist>
    </div>
    """
  end
end
