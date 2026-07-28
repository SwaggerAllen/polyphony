defmodule PolyphonyWeb.SheetEditorLive do
  @moduledoc """
  V4 (sheet editor): edit a character's authored sheet; promote a stub (§B8); and
  build rich fields with AI assistance.

  Prose fields are edited as **blocks** (paragraphs): each block is an always-live,
  auto-growing textarea styled to read like prose until focused — long content stays
  readable instead of trapped in a scroll box. Every block can be regenerated;
  fields can be **Generated** fresh (from a brief), **Expanded** (append a paragraph
  that deepens them), or built a paragraph at a time. Generation is grounded in the
  linked world bible and the character's relationships. Blocks are joined with blank
  lines into the plain-string field on save, so the domain is unchanged.

  Relationships link existing characters or **stub** new ones on save; the author can
  also ask for AI **suggestions**.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{Autofill, CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Relationship

  # Prose fields are edited as blocks; name stays a single-line scalar.
  @field_specs [
    {"premise", "Premise"},
    {"appearance", "Appearance"},
    {"voice", "Voice"},
    {"temperament", "Temperament"},
    {"backstory", "Backstory"}
  ]
  @block_fields Enum.map(@field_specs, &elem(&1, 0))

  defp field_specs, do: @field_specs

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "character" do
      # struct/2 fills any field the stored struct predates (e.g. world_bible_id).
      sheet = struct(CharacterSheet, Map.from_struct(Library.payload(entry)))
      worlds = load_worlds(socket.assigns.current_user)
      world_id = if sheet.world_bible_id, do: to_string(sheet.world_bible_id), else: ""

      {:ok,
       socket
       |> assign(
         page_title: "Edit character",
         entry: entry,
         sheet: sheet,
         name: sheet.name || "",
         blocks: blocks_from_sheet(sheet),
         generating: MapSet.new(),
         saved: false,
         dirty: false,
         world_entries: worlds,
         worlds: world_options(worlds),
         world_id: world_id,
         world_context: world_context_for(worlds, world_id),
         relationships: sheet.relationships || [],
         relations_context:
           relations_context(sheet.relationships || [], socket.assigns.current_user, entry.id)
       )
       |> assign_characters(other_characters(socket.assigns.current_user, entry.id))}
    else
      {:ok, socket |> put_flash(:error, "Character not found.") |> redirect(to: ~p"/library")}
    end
  end

  # ── Editing the sheet form ──────────────────────────────────────────────────

  def handle_event("sync", params, socket) do
    {:noreply, socket |> assign_form(params) |> touch()}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      %{current_user: user, entry: %{id: id}} = socket.assigns
      socket = assign_form(socket, params)
      %{name: name, blocks: blocks, relationships: rels} = socket.assigns

      existing = char_names(other_characters(user, id))
      world_bible_id = world_id_int(socket.assigns.world_id)
      stubbed = seed_stubs(rels, existing, name, Owner.of(user), world_bible_id)

      sheet = %CharacterSheet{
        socket.assigns.sheet
        | name: name,
          premise: join_blocks(blocks["premise"]),
          appearance: join_blocks(blocks["appearance"]),
          voice: join_blocks(blocks["voice"]),
          temperament: join_blocks(blocks["temperament"]),
          backstory: join_blocks(blocks["backstory"]),
          world_bible_id: world_id_int(socket.assigns.world_id),
          relationships: rels,
          # Saving finalizes a pending stub — the author has reviewed it by editing
          # and saving, so it silently becomes a usable (:full) character.
          status: :full
      }

      {:ok, entry} = Library.update_payload(id, sheet)

      socket =
        socket
        |> assign(
          entry: entry,
          sheet: sheet,
          name: sheet.name || "",
          blocks: blocks_from_sheet(sheet),
          saved: true,
          dirty: false
        )
        |> assign_characters(other_characters(user, id))
        |> assign_relationships(rels)

      {:noreply, maybe_flash_stubs(socket, stubbed)}
    end)
  end

  def handle_event("add_block", %{"field" => f}, socket) when f in @block_fields do
    {:noreply, update_blocks(socket, f, &(&1 ++ [""]))}
  end

  def handle_event("remove_block", %{"field" => f, "index" => i}, socket)
      when f in @block_fields do
    idx = String.to_integer(i)
    {:noreply, update_blocks(socket, f, &drop_block(&1, idx))}
  end

  def handle_event("select_world", %{"world_id" => id}, socket) do
    {:noreply,
     socket
     |> assign(world_id: id, world_context: world_context_for(socket.assigns.world_entries, id))
     |> touch()}
  end

  # ── Generation ──────────────────────────────────────────────────────────────

  def handle_event("generate_all", %{"brief" => brief}, socket) do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> mark("all", true)
       |> start_async(:gen_all, fn -> Autofill.generate_all(:character, brief, current, opts) end)}
    end)
  end

  def handle_event("generate_field", %{"field" => f}, socket) when f in @block_fields do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> mark(f, true)
       |> start_async({:gen_field, f}, fn ->
         Autofill.generate_field(:character, f, current, opts)
       end)}
    end)
  end

  def handle_event("expand_field", %{"field" => f}, socket) when f in @block_fields do
    safe(socket, fn ->
      opts = paragraph_opts(socket, f, nil)

      {:noreply,
       socket
       |> mark("#{f}:expand", true)
       |> start_async({:expand, f}, fn -> Autofill.generate_paragraph(:character, f, opts) end)}
    end)
  end

  def handle_event("generate_block", %{"field" => f, "index" => i}, socket)
      when f in @block_fields do
    idx = String.to_integer(i)

    safe(socket, fn ->
      opts = paragraph_opts(socket, f, idx)

      {:noreply,
       socket
       |> mark("#{f}:#{idx}", true)
       |> start_async({:gen_block, f, idx}, fn ->
         Autofill.generate_paragraph(:character, f, opts)
       end)}
    end)
  end

  # ── Relationships ─────────────────────────────────────────────────────────────

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
           |> touch()}
      end
    end)
  end

  def handle_event("remove_relationship", %{"index" => i}, socket) do
    idx = String.to_integer(i)

    {:noreply,
     socket
     |> assign_relationships(List.delete_at(socket.assigns.relationships, idx))
     |> touch()}
  end

  def handle_event("suggest_relationships", _params, socket) do
    safe(socket, fn ->
      current = current_values(socket)
      opts = [existing: socket.assigns.relationships] ++ gen_opts(socket)

      {:noreply,
       socket
       |> mark("relationships", true)
       |> start_async(:suggest_rel, fn -> Autofill.suggest_relationships(current, opts) end)}
    end)
  end

  # ── Async generation results ──────────────────────────────────────────────────

  def handle_async(:gen_all, {:ok, {:ok, values}}, socket) do
    blocks =
      Enum.reduce(values, socket.assigns.blocks, fn {f, v}, acc ->
        if f in @block_fields, do: Map.put(acc, f, to_blocks(v)), else: acc
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]
    {:noreply, socket |> assign(name: name, blocks: blocks) |> mark("all", false) |> touch()}
  end

  def handle_async(:gen_all, result, socket), do: {:noreply, gen_failed(socket, "all", result)}

  def handle_async({:gen_field, f}, {:ok, {:ok, value}}, socket) do
    {:noreply, socket |> put_blocks(f, to_blocks(value)) |> mark(f, false) |> touch()}
  end

  def handle_async({:gen_field, f}, result, socket),
    do: {:noreply, gen_failed(socket, f, result)}

  def handle_async({:expand, f}, {:ok, {:ok, para}}, socket) do
    blocks = append_paragraph(socket.assigns.blocks[f], para)
    {:noreply, socket |> put_blocks(f, blocks) |> mark("#{f}:expand", false) |> touch()}
  end

  def handle_async({:expand, f}, result, socket),
    do: {:noreply, gen_failed(socket, "#{f}:expand", result)}

  def handle_async({:gen_block, f, idx}, {:ok, {:ok, para}}, socket) do
    blocks = List.replace_at(socket.assigns.blocks[f], idx, para)
    {:noreply, socket |> put_blocks(f, blocks) |> mark("#{f}:#{idx}", false) |> touch()}
  end

  def handle_async({:gen_block, f, idx}, result, socket),
    do: {:noreply, gen_failed(socket, "#{f}:#{idx}", result)}

  def handle_async(:suggest_rel, {:ok, {:ok, suggestions}}, socket) do
    socket = mark(socket, "relationships", false)

    case suggestions do
      [] ->
        {:noreply, put_flash(socket, :info, "No new relationships suggested.")}

      list ->
        rels =
          Enum.map(list, fn s ->
            %Relationship{target: s["target"], descriptor: s["descriptor"]}
          end)

        {:noreply,
         socket
         |> assign_relationships(socket.assigns.relationships ++ rels)
         |> touch()
         |> put_flash(:info, "Added #{length(rels)} suggested relationship(s). Review and Save.")}
    end
  end

  def handle_async(:suggest_rel, result, socket),
    do: {:noreply, gen_failed(socket, "relationships", result)}

  # ── Assign / block helpers ────────────────────────────────────────────────────

  # Mark the form as having unsaved edits (hides the ✓ indicator, arms the
  # leave-confirmation on navigation links).
  defp touch(socket), do: assign(socket, saved: false, dirty: true)

  defp assign_form(socket, params) do
    name = params["name"] || socket.assigns.name

    blocks =
      Map.new(@block_fields, fn f ->
        {f, param_blocks(params["b_#{f}"], socket.assigns.blocks[f])}
      end)

    assign(socket, name: name, blocks: blocks)
  end

  defp update_blocks(socket, field, fun),
    do: socket |> put_blocks(field, fun.(socket.assigns.blocks[field])) |> touch()

  defp put_blocks(socket, field, blocks),
    do: assign(socket, :blocks, Map.put(socket.assigns.blocks, field, ensure_one(blocks)))

  defp blocks_from_sheet(sheet) do
    Map.new(@block_fields, fn f -> {f, to_blocks(Map.get(sheet, String.to_existing_atom(f)))} end)
  end

  defp current_values(socket) do
    Map.merge(
      %{"name" => socket.assigns.name},
      Map.new(@block_fields, fn f -> {f, join_blocks(socket.assigns.blocks[f])} end)
    )
  end

  defp paragraph_opts(socket, field, index) do
    [blocks: socket.assigns.blocks[field], index: index, current: current_values(socket)] ++
      gen_opts(socket)
  end

  # World seed + related-character sheets + the stub's inherited role + usage
  # attribution for a metered call. `role` (a former stub's one-line seed, e.g.
  # "estranged mentor") grounds generation so the source character's framing survives
  # into the generated sheet; nil for a deliberately-created character.
  defp gen_opts(socket) do
    [
      world: socket.assigns.world_context,
      relations: socket.assigns.relations_context,
      role: socket.assigns.sheet.role,
      usage_kind: "authoring"
    ] ++ user_attribution(socket)
  end

  defp user_attribution(socket) do
    case socket.assigns.current_user do
      %{id: id} -> [user_id: id]
      _ -> []
    end
  end

  defp mark(socket, key, true),
    do: assign(socket, :generating, MapSet.put(socket.assigns.generating, key))

  defp mark(socket, key, false),
    do: assign(socket, :generating, MapSet.delete(socket.assigns.generating, key))

  defp gen_failed(socket, key, result) do
    Logger.warning("[authoring] generation failed (#{key}): #{inspect(result)}")

    socket
    |> mark(key, false)
    |> put_flash(:error, "Generation failed: #{inspect(reason(result))}")
  end

  defp reason({:ok, {:error, r}}), do: r
  defp reason({:exit, r}), do: r
  defp reason(other), do: other

  # ── Relationships helpers ─────────────────────────────────────────────────────

  defp assign_relationships(socket, relationships) do
    assign(socket,
      relationships: relationships,
      relations_context:
        relations_context(relationships, socket.assigns.current_user, socket.assigns.entry.id)
    )
  end

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

  defp seed_stubs(relationships, existing_names, self_name, owner, world_bible_id) do
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

      role = inbound |> Enum.map(& &1.descriptor) |> Enum.find("", &(&1 not in [nil, ""]))

      Library.put(%{
        owner: owner,
        kind: "character",
        payload: Stub.new(target, role, relationships: inbound, world_bible_id: world_bible_id)
      })

      target
    end)
  end

  defp maybe_flash_stubs(socket, []), do: socket

  defp maybe_flash_stubs(socket, names),
    do: put_flash(socket, :info, "Stubbed new character(s): #{Enum.join(names, ", ")}.")

  # The owner's other character entries — powers the relationship datalist (names)
  # and the "open this character" links (name → id).
  defp other_characters(user, exclude_id) do
    user
    |> Library.list_for_owner()
    |> Enum.filter(&(&1.kind == "character" and &1.id != exclude_id))
  end

  defp assign_characters(socket, entries),
    do: assign(socket, char_names: char_names(entries), char_links: char_links(entries))

  defp char_names(entries), do: entries |> Enum.map(&char_name/1) |> Enum.reject(&is_nil/1)

  defp char_links(entries) do
    for e <- entries,
        name = char_name(e),
        name != nil,
        into: %{},
        do: {String.downcase(name), e.id}
  end

  defp char_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  defp world_id_int(""), do: nil
  defp world_id_int(nil), do: nil
  defp world_id_int(id) when is_binary(id), do: String.to_integer(id)

  defp load_worlds(user),
    do: user |> Library.list_for_owner() |> Enum.filter(&(&1.kind == "world_bible"))

  defp world_options(entries), do: for(e <- entries, do: {to_string(e.id), world_name(e)})

  defp world_name(entry) do
    case Library.payload(entry) do
      %WorldBible{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled world (##{entry.id})"
    end
  end

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

  # ── Render ────────────────────────────────────────────────────────────────────

  # A relationship's target: a link to that character's editor when it's an existing
  # (or already-saved-stub) character, otherwise plain text.
  attr(:target, :string, required: true)
  attr(:links, :map, required: true)
  attr(:confirm, :string, default: nil)

  defp rel_target(assigns) do
    assigns = assign(assigns, :id, Map.get(assigns.links, String.downcase(assigns.target)))

    ~H"""
    <a :if={@id} href={~p"/authoring/character/#{@id}"} data-confirm={@confirm}>
      <strong><%= @target %></strong>
    </a>
    <strong :if={is_nil(@id)}><%= @target %></strong>
    """
  end

  # The leave-confirmation message when there are unsaved edits, else nil (which
  # renders no data-confirm attribute, so a clean page never prompts).
  defp leave_confirm(true), do: "You have unsaved changes. Leave without saving?"
  defp leave_confirm(false), do: nil

  def render(assigns) do
    ~H"""
    <div class="row">
      <h1>Edit character</h1>
      <div class="spacer"></div>
      <span :if={@sheet.status != :full} class="badge stub">pending</span>
    </div>

    <div :if={@sheet.status != :full} class="card">
      <p class="dim">
        This character is <strong>pending</strong> — it came from another character's
        relationships<span :if={@sheet.role not in [nil, ""]}> as their <em><%= @sheet.role %></em></span>.
        Fill in the fields below (write them yourself or use ✨ Generate) and Save to finish it.
      </p>
    </div>

    <div class="card gen-brief">
      <form id="world-select-form" phx-change="select_world">
        <label>World <span class="faint">(grounds generated backstory &amp; voice in a setting)</span></label>
        <select name="world_id">
          <option value="">— none —</option>
          <option :for={{id, name} <- @worlds} value={id} selected={@world_id == id}><%= name %></option>
        </select>
        <p :if={@worlds == []} class="faint">
          No world bibles yet — create one in the <a href={~p"/library"} data-confirm={leave_confirm(@dirty)}>Library</a> to ground generation.
        </p>
      </form>

      <form phx-submit="generate_all">
        <label>Describe the character — we'll fill in every field <span class="faint">(builds on anything you've already written)</span></label>
        <textarea
          name="brief"
          rows="2"
          placeholder="e.g. A jaded harbor-town detective who used to be a priest and still prays out of habit."
        ></textarea>
        <button class="btn" type="submit" disabled={busy?(@generating, "all")}>
          <%= if busy?(@generating, "all"), do: "✨ Generating…", else: "✨ Generate all fields" %>
        </button>
      </form>
    </div>

    <div class="card">
      <form id="sheet-form" phx-submit="save" phx-change="sync">
        <label class="gen-label"><span>Name</span></label>
        <input type="text" name="name" value={@name} phx-debounce="blur" />

        <.block_field
          :for={{f, label} <- field_specs()}
          field={f}
          label={label}
          blocks={@blocks[f]}
          generating={@generating}
        />

        <div class="row save-row">
          <button class="btn" type="submit">Save</button>
          <span :if={@saved} class="saved-note" role="status">✓ Saved</span>
          <span class="spacer"></span>
          <a class="btn ghost" href={~p"/library"} data-confirm={leave_confirm(@dirty)}>Back to library</a>
        </div>
      </form>
    </div>

    <div class="card">
      <div class="row">
        <h3>Relationships</h3>
        <div class="spacer"></div>
        <button
          type="button"
          class="btn sm ghost"
          phx-click="suggest_relationships"
          disabled={busy?(@generating, "relationships")}
        >
          <%= if busy?(@generating, "relationships"), do: "✨ …", else: "✨ Suggest" %>
        </button>
      </div>
      <p class="dim">
        How this character regards others. Pick an existing character or type a new name —
        a new name becomes a <strong>stub</strong> character, created when you Save.
        <strong>✨ Suggest</strong> adds AI-proposed relationships straight to the list.
      </p>

      <div :if={@relationships == []} class="faint">No relationships yet.</div>
      <ul class="rel-list">
        <li :for={{r, i} <- Enum.with_index(@relationships)} class="row rel-item">
          <span>→ <.rel_target target={r.target} links={@char_links} confirm={leave_confirm(@dirty)} /><span :if={r.descriptor not in [nil, ""]}> — <%= r.descriptor %></span></span>
          <span class="spacer"></span>
          <button type="button" class="btn danger sm" phx-click="remove_relationship" phx-value-index={i}>Remove</button>
        </li>
      </ul>

      <form id="rel-form" phx-submit="add_relationship" class="row rel-add">
        <input type="text" name="target" list="char-names" placeholder="Character name…" autocomplete="off" />
        <input type="text" name="descriptor" placeholder="how they regard them (e.g. estranged mentor)" style="flex:1;" />
        <button class="btn" type="submit">Add</button>
      </form>
      <datalist id="char-names">
        <option :for={n <- @char_names} value={n}></option>
      </datalist>
    </div>
    """
  end
end
