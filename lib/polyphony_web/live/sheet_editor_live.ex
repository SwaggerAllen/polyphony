defmodule PolyphonyWeb.SheetEditorLive do
  @moduledoc """
  V4 (sheet editor): edit a character's authored sheet and build rich fields with AI
  assistance. A stub (§B8) reads as *pending* and is finalized to `:full` silently on
  save — there is no separate promote/accept step.

  Prose fields are edited as **blocks** (paragraphs): each block is an always-live,
  auto-growing textarea styled to read like prose until focused — long content stays
  readable instead of trapped in a scroll box. Every block can be regenerated;
  fields can be **Generated** fresh (from a brief), **Expanded** (append a paragraph
  that deepens them), or built a paragraph at a time. Generation is grounded in the
  linked world bible, the character's relationships, and (for a former stub) its
  inherited `role`. Blocks are joined with blank lines into the plain-string field on
  save, so the domain is unchanged.

  Relationships link existing characters or **stub** new ones on save; the author can
  also ask for AI **suggestions**. When a stub is seeded, its regard back toward the
  generating character is generated asynchronously (`Autofill.reciprocal_roles`) so
  the two directions can be asymmetrical rather than a copied descriptor.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.{Autofill, CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.{Relationship, Boundary}

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
         role: sheet.role || "",
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
           relations_context(sheet.relationships || [], socket.assigns.current_user, entry.id),
         boundaries: sheet.boundaries || []
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

  # Edit a pending stub's one-line role (how they fit / how the source regards them). It
  # seeds ✨ Generate and is persisted on Save, so authors can correct a stub the Director
  # or a relationship proposed with a wrong role before finalizing it.
  def handle_event("set_role", %{"role" => role}, socket) do
    {:noreply, socket |> assign(role: role) |> touch()}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      %{current_user: user, entry: %{id: id}} = socket.assigns
      socket = assign_form(socket, params)
      %{name: name, blocks: blocks, relationships: rels} = socket.assigns

      existing_entries = other_characters(user, id)
      existing = char_names(existing_entries)
      world_bible_id = world_id_int(socket.assigns.world_id)
      stubbed = seed_stubs(rels, existing, name, Owner.of(user), world_bible_id, id)

      # Every relationship that names a real character (existing or just-stubbed) now
      # carries its stable id, so links and context resolve by id, not name.
      rels = resolve_target_ids(rels, existing_entries, stubbed)

      sheet = %CharacterSheet{
        socket.assigns.sheet
        | name: name,
          role: blank_to_nil(socket.assigns.role),
          premise: join_blocks(blocks["premise"]),
          appearance: join_blocks(blocks["appearance"]),
          voice: join_blocks(blocks["voice"]),
          temperament: join_blocks(blocks["temperament"]),
          backstory: join_blocks(blocks["backstory"]),
          world_bible_id: world_id_int(socket.assigns.world_id),
          relationships: rels,
          boundaries: socket.assigns.boundaries,
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

      socket =
        socket
        |> maybe_flash_stubs(stubbed)
        |> generate_reciprocals(stubbed, name, id)

      {:noreply, socket}
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
          # Link to an existing character by id when the typed name matches one; else
          # leave target_id nil (a new name that stubs on save, then gets linked).
          target_id = Map.get(socket.assigns.char_links, String.downcase(name))

          rel = %Relationship{
            target: name,
            target_id: target_id,
            descriptor: String.trim(params["descriptor"] || "")
          }

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

  # ── Boundaries (§A3) ────────────────────────────────────────────────────────

  def handle_event("add_boundary", params, socket) do
    safe(socket, fn ->
      case String.trim(params["topic"] || "") do
        "" ->
          {:noreply, put_flash(socket, :error, "Give the boundary a topic.")}

        topic ->
          boundary = %Boundary{
            topic: topic,
            stance: parse_stance(params["stance"]),
            condition: blank_to_nil(params["condition"]),
            on_pressure: blank_to_nil(params["on_pressure"]),
            category: parse_category(params["category"])
          }

          {:noreply,
           socket
           |> assign(boundaries: socket.assigns.boundaries ++ [boundary])
           |> touch()}
      end
    end)
  end

  def handle_event("remove_boundary", %{"index" => i}, socket) do
    idx = String.to_integer(i)

    {:noreply,
     socket
     |> assign(boundaries: List.delete_at(socket.assigns.boundaries, idx))
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

  # Reciprocal generation is best-effort background enrichment of the just-created
  # stubs — never surfaced as an error. On success, patch each stub's regard toward
  # this character; on failure, the placeholder descriptor stands.
  def handle_async(:reciprocals, {:ok, {stubs, self_name, self_id, {:ok, reciprocals}}}, socket) do
    for %{id: id, target: target} <- stubs, r = reciprocals[target], present_string?(r) do
      patch_stub_reciprocal(id, self_name, self_id, r)
    end

    {:noreply, socket}
  end

  def handle_async(:reciprocals, result, socket) do
    Logger.warning("[authoring] reciprocal generation skipped: #{inspect(result)}")
    {:noreply, socket}
  end

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
      # The live, possibly-edited role (falls back to the stub's inherited one).
      role: blank_to_nil(socket.assigns.role) || socket.assigns.sheet.role,
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
    chars =
      user
      |> Library.list_for_owner()
      |> Enum.filter(&(&1.kind == "character" and &1.id != exclude_id))

    by_id = Map.new(chars, &{&1.id, &1})
    by_name = Map.new(chars, &{String.downcase(char_name(&1) || ""), &1})

    for r <- relationships,
        entry =
          (r.target_id && Map.get(by_id, r.target_id)) ||
            Map.get(by_name, String.downcase(r.target || "")),
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

  # Create a stub for each newly-referenced relationship target. The stub's inbound
  # relationship (stub → self) is seeded with the source's descriptor as a placeholder
  # and its `reciprocal` records how the source regards the stub; the asymmetrical
  # stub-→-self regard is generated afterwards (`generate_reciprocals`). `role`
  # describes the stub (the source's regard of them). Returns `[%{id, target,
  # descriptor}]` for the stubs created, feeding the flash and reciprocal generation.
  defp seed_stubs(relationships, existing_names, self_name, owner, world_bible_id, self_id) do
    existing = MapSet.new(existing_names, &String.downcase/1)
    self_down = String.downcase(self_name || "")
    # A target already linked to a real character (target_id set) is never stubbed.
    linked = for r <- relationships, r.target_id != nil, into: MapSet.new(), do: r.target

    relationships
    |> Enum.map(& &1.target)
    |> Enum.uniq()
    |> Enum.reject(fn t ->
      t == "" or String.downcase(t) == self_down or
        MapSet.member?(existing, String.downcase(t)) or MapSet.member?(linked, t)
    end)
    |> Enum.map(fn target ->
      matching = Enum.filter(relationships, &(&1.target == target))
      role = matching |> Enum.map(& &1.descriptor) |> Enum.find("", &(&1 not in [nil, ""]))

      inbound =
        for r <- matching,
            do: %Relationship{
              target: self_name,
              target_id: self_id,
              descriptor: r.descriptor,
              reciprocal: r.descriptor
            }

      entry =
        Library.put(%{
          owner: owner,
          kind: "character",
          payload: Stub.new(target, role, relationships: inbound, world_bible_id: world_bible_id)
        })

      %{id: entry.id, target: target, descriptor: role}
    end)
  end

  # Fill in each relationship's `target_id` from the characters that now exist — the
  # owner's other characters and the stubs just created — matching by name once. A
  # relationship that already has an id, or names no real character, is left as-is.
  defp resolve_target_ids(relationships, existing_entries, stubbed) do
    by_name =
      for e <- existing_entries, n = char_name(e), n != nil, into: %{} do
        {String.downcase(n), e.id}
      end

    lookup =
      Enum.reduce(stubbed, by_name, fn s, acc ->
        Map.put(acc, String.downcase(s.target), s.id)
      end)

    Enum.map(relationships, fn r ->
      %Relationship{
        r
        | target_id: r.target_id || Map.get(lookup, String.downcase(r.target || ""))
      }
    end)
  end

  # Best-effort async enrichment: generate each new stub's asymmetrical regard back
  # toward the character being saved, then patch it into the stub. Runs after save so
  # the save itself never blocks on a provider call; a failure leaves the placeholder.
  defp generate_reciprocals(socket, [], _self_name, _self_id), do: socket

  defp generate_reciprocals(socket, stubs, self_name, self_id) do
    source = current_values(socket)
    pairs = Enum.map(stubs, &%{"target" => &1.target, "descriptor" => &1.descriptor})
    opts = gen_opts(socket)

    start_async(socket, :reciprocals, fn ->
      {stubs, self_name, self_id, Autofill.reciprocal_roles(source, pairs, opts)}
    end)
  end

  defp maybe_flash_stubs(socket, []), do: socket

  defp maybe_flash_stubs(socket, stubs),
    do:
      put_flash(
        socket,
        :info,
        "Stubbed new character(s): #{Enum.map_join(stubs, ", ", & &1.target)}."
      )

  # Set the stub's regard toward `self_name` to the generated reciprocal, keeping the
  # source's regard of the stub as its `reciprocal`. Best-effort: a vanished/edited
  # stub is left alone.
  defp patch_stub_reciprocal(id, self_name, self_id, reciprocal) do
    with entry when not is_nil(entry) <- Library.get(id),
         %CharacterSheet{} = sheet <- Library.payload(entry) do
      rels =
        Enum.map(sheet.relationships || [], fn rel ->
          if rel.target_id == self_id or rel.target == self_name,
            do: %Relationship{rel | descriptor: reciprocal, reciprocal: rel.reciprocal},
            else: rel
        end)

      Library.update_payload(id, %CharacterSheet{sheet | relationships: rels})
    end
  end

  defp present_string?(v), do: is_binary(v) and String.trim(v) != ""

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
  attr(:target_id, :integer, default: nil)
  attr(:links, :map, required: true)
  attr(:confirm, :string, default: nil)

  defp rel_target(assigns) do
    # Prefer the stable id; fall back to a name lookup for un-linked (legacy) rels.
    id = assigns.target_id || Map.get(assigns.links, String.downcase(assigns.target))
    assigns = assign(assigns, :id, id)

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
        relationships. Set their role, fill in the fields below (write them yourself or
        use ✨ Generate), and Save to finish it.
      </p>
      <form id="stub-role-form" phx-change="set_role">
        <label>Role <span class="faint">(one line — how they fit; seeds ✨ Generate)</span></label>
        <input
          type="text"
          name="role"
          value={@role}
          placeholder="e.g. estranged mentor, harbor smuggler"
          autocomplete="off"
          phx-debounce="blur"
        />
      </form>
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

      <form id="sheet-generate-all" phx-submit="generate_all">
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
          <span>→ <.rel_target target={r.target} target_id={r.target_id} links={@char_links} confirm={leave_confirm(@dirty)} /><span :if={r.descriptor not in [nil, ""]}> — <%= r.descriptor %></span></span>
          <span class="spacer"></span>
          <button type="button" class="btn danger sm" phx-click="remove_relationship" phx-value-index={i}>Remove</button>
        </li>
      </ul>

      <form id="rel-form" phx-submit="add_relationship" class="rel-add">
        <label>Character <span class="faint">(existing name, or a new one to stub)</span>
          <input type="text" name="target" list="char-names" placeholder="Character name…" autocomplete="off" />
        </label>
        <label>How they regard them
          <input type="text" name="descriptor" placeholder="e.g. estranged mentor" />
        </label>
        <button class="btn" type="submit" style="margin-top:.4rem;">Add relationship</button>
      </form>
      <datalist id="char-names">
        <option :for={n <- @char_names} value={n}></option>
      </datalist>
    </div>

    <div class="card">
      <h3>Boundaries</h3>
      <p class="dim">
        Lines this character holds. A refusal is played as a scene beat, never a filter (§A3).
        A <strong>conditional</strong> boundary holds until its condition is earned in the story
        (slow burn); an optional <strong>category</strong> lets a campaign's content ceiling cap it.
      </p>

      <div :if={@boundaries == []} class="faint">No boundaries yet.</div>
      <ul class="rel-list">
        <li :for={{b, i} <- Enum.with_index(@boundaries)} class="row rel-item">
          <span><%= boundary_line(b) %></span>
          <span class="spacer"></span>
          <button type="button" class="btn danger sm" phx-click="remove_boundary" phx-value-index={i}>Remove</button>
        </li>
      </ul>

      <form id="boundary-form" phx-submit="add_boundary" style="margin-top:.5rem;">
        <label>Topic
          <input type="text" name="topic" placeholder="e.g. physical intimacy, killing" autocomplete="off" />
        </label>
        <label>Stance
          <select name="stance">
            <option value="closed">Hard line — will not</option>
            <option value="conditional">Conditional — until…</option>
            <option value="open">Open to it</option>
          </select>
        </label>
        <label>Category <span class="faint">(optional — a campaign's ceiling can cap it)</span>
          <select name="category">
            <option value="">No category</option>
            <option value="sexual">Sexual</option>
            <option value="graphic_violence">Graphic violence</option>
            <option value="other">Other</option>
          </select>
        </label>
        <label>Condition <span class="faint">(conditional only — until what happens?)</span>
          <input type="text" name="condition" placeholder="e.g. once trust is earned" />
        </label>
        <label>When pushed <span class="faint">(optional — how they react under pressure)</span>
          <input type="text" name="on_pressure" placeholder="e.g. deflects with a joke" />
        </label>
        <button class="btn" type="submit" style="margin-top:.6rem;">Add boundary</button>
      </form>
    </div>
    """
  end

  # Human-readable one-line summary of a boundary for the list.
  defp boundary_line(%Boundary{} = b) do
    extras =
      [condition_bit(b), pressure_bit(b), category_bit(b)] |> Enum.reject(&is_nil/1)

    suffix = if extras == [], do: "", else: " · " <> Enum.join(extras, " · ")
    "#{b.topic} — #{stance_label(b.stance)}" <> suffix
  end

  defp stance_label(:open), do: "open to it"
  defp stance_label(:conditional), do: "held until earned"
  defp stance_label(:closed), do: "a hard line"
  defp stance_label(_), do: "holds back"

  defp condition_bit(%Boundary{stance: :conditional, condition: c}) when is_binary(c) and c != "",
    do: "until #{c}"

  defp condition_bit(_), do: nil

  defp pressure_bit(%Boundary{on_pressure: p}) when is_binary(p) and p != "",
    do: "when pushed: #{p}"

  defp pressure_bit(_), do: nil

  defp category_bit(%Boundary{category: nil}), do: nil
  defp category_bit(%Boundary{category: cat}), do: "capped by #{cat}"

  defp parse_stance("open"), do: :open
  defp parse_stance("conditional"), do: :conditional
  defp parse_stance(_), do: :closed

  defp parse_category("sexual"), do: :sexual
  defp parse_category("graphic_violence"), do: :graphic_violence
  defp parse_category("other"), do: :other
  defp parse_category(_), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
