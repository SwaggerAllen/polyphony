defmodule PolyphonyWeb.SheetEditorLive do
  @moduledoc """
  The character sheet, ported from `ux/polyphony-character.html`.

  ## A sheet is read, not just filled in

  The mock's §00 is the whole layout argument, and the port follows it literally.
  **No tabs, no accordions** — you come back to a sheet to remember who someone is,
  which means reading top to bottom; a sticky `Kit.jump` bar handles the length
  instead, giving position without hiding anything. **Prose first, structure after**
  — the five written fields run continuously like a page, and the lists sit below
  them. **Nothing says "core" or "status"**: the model's vocabulary isn't the
  author's, so *Always in mind* replaces `core: true` and actually explains the
  behaviour it controls.

  Everything editable is edited **in place**. There is no read mode and edit mode,
  because the two would be the same screen twice.

  ## Facts, and the two flags that compose

  `core` and `concealed` are orthogonal and are not collapsed: *always in mind* is
  whether **she** carries it, *secret* is who **else** has it — a woman can have a
  secret she never thinks about. Only one of them can own the left border, so secret
  takes the structure (`Kit.marked mark={:secret}`) and always-in-mind is a chip.

  ## Two directions of pressure

  `Boundary.direction` splits the list in two — *what she won't do* and *what she
  can't stop doing*. The grouping is the point: an item in its own list can never be
  read backwards, which is what went wrong when everything was one list of "lines".

  ## Generation

  Prose fields are edited as **blocks** (paragraphs) — `PolyphonyWeb.BlockField` — so
  a long field stays readable and a single paragraph can be rewritten without
  touching the rest. Fields can be rewritten whole, expanded by a paragraph, or
  written from a brief; facts, relationships and pressures each have ✦ Suggest.
  Generation is grounded in the linked world bible, the character's relationships,
  and (for a former stub) its inherited `role`. Blocks join with blank lines into the
  plain-string field on save, so the domain struct is unchanged.

  A stub (§B8) reads as *pending* and is finalized to `:full` silently on save —
  there is no separate promote step; editing and saving **is** the review.

  Relationships link existing characters or **stub** new ones on save. When a stub is
  seeded, its regard back toward the generating character is generated asynchronously
  (`Autofill.reciprocal_roles`) so the two directions can be asymmetrical rather than
  a copied descriptor.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.{Campaigns, Characters, Groups, Library, Owner, Repo}
  alias Polyphony.Authoring.{Audience, CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Fact, Relationship}
  alias Polyphony.ReadModels.Membership
  alias Polyphony.Permissions
  alias PolyphonyWeb.{AudiencePicker, Autosave, Generating, Guard, Kit, Layouts, Voice}

  # Prose fields are edited as blocks; name stays a single-line scalar.
  @field_specs [
    {"premise", "Premise"},
    {"appearance", "Appearance"},
    {"voice", "Voice"},
    {"temperament", "Temperament"},
    {"backstory", "Backstory"}
  ]
  @block_fields Enum.map(@field_specs, &elem(&1, 0))

  # The jump bar's stops, in the order the sheet runs. Cover leads because it is
  # what a stranger reads first, which is the only ordering argument it has.
  @stops [
    {"cover", "Cover"},
    {"premise", "Premise"},
    {"appearance", "Appearance"},
    {"voice", "Voice"},
    {"temperament", "Temperament"},
    {"backstory", "Backstory"},
    {"facts", "Facts"},
    {"knows", "Who they know"},
    {"pushed", "Pushed"},
    {"groups", "Groups"}
  ]

  defp field_specs, do: @field_specs
  defp stops, do: @stops

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "character" &&
         Permissions.can_edit?(entry, socket.assigns.current_user) do
      # struct/2 fills any field the stored struct predates (e.g. world_bible_id).
      sheet = struct(CharacterSheet, Map.from_struct(Library.payload(entry)))
      worlds = load_worlds(socket.assigns.current_user)
      world_id = if sheet.world_bible_id, do: to_string(sheet.world_bible_id), else: ""

      {:ok,
       socket
       |> assign(
         page_title: sheet.name || "Character",
         entry: entry,
         sheet: sheet,
         name: sheet.name || "",
         pronouns: sheet.pronouns || "",
         role: sheet.role || "",
         tier: sheet.tier || :main,
         cover: sheet.cover,
         blocks: blocks_from_sheet(sheet),
         gen_subject: entry.id,
         generating: MapSet.new(),
         saved: false,
         dirty: false,
         autosave_ref: nil,
         brief_open: false,
         drawer: nil,
         panel: nil,
         # Index of the fact whose audience is open, or nil.
         audience_at: nil,
         world_entries: worlds,
         worlds: world_options(worlds),
         world_id: world_id,
         world_context: world_context_for(worlds, world_id),
         relationships: sheet.relationships || [],
         relations_context:
           relations_context(sheet.relationships || [], socket.assigns.current_user, entry.id),
         boundaries: sheet.boundaries || [],
         facts: sheet.facts || [],
         scene_count: scene_count(entry.id),
         groups: Groups.for_character(Owner.of(socket.assigns.current_user), entry.id),
         all_groups: Groups.list(Owner.of(socket.assigns.current_user))
       )
       |> Generating.restore()
       |> assign_audience_sources()
       |> assign_knows()
       |> assign_characters(other_characters(socket.assigns.current_user, entry.id))}
    else
      Guard.refuse(socket, entry, "Character", socket.assigns.current_user)
    end
  end

  # The read model is only populated by the projectors, which are off in tests and
  # empty before anyone has played — "In 0 scenes" is the honest answer either way,
  # and a missing table must not take the sheet down with it.
  defp scene_count(id) do
    Membership.scene_count(Repo, id)
  rescue
    _ -> 0
  end

  # ── Editing the sheet form ──────────────────────────────────────────────────

  @doc false
  # The open panel, drawer and picker live in the **URL** rather than in the socket —
  # see `BibleEditorLive.handle_params/3` for why, and for what it buys on a phone.
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       panel: present(params["panel"]),
       drawer: present(params["drawer"]),
       audience_at: decode_index(params["audience"])
     )}
  end

  defp decode_index(nil), do: nil

  defp decode_index(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, ""} when i >= 0 -> i
      _ -> nil
    end
  end

  defp decode_index(i) when is_integer(i), do: i

  defp view_patch(socket, changes) do
    params =
      %{
        "panel" => socket.assigns.panel,
        "drawer" => socket.assigns.drawer,
        "audience" => socket.assigns.audience_at
      }
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> v in [nil, false, ""] end)

    push_patch(socket, to: ~p"/authoring/character/#{socket.assigns.entry.id}?#{params}")
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value

  def handle_event("sync", params, socket) do
    {:noreply, socket |> assign_form(params) |> touch()}
  end

  # Edit a pending stub's one-line role (how they fit / how the source regards them). It
  # seeds ✨ Generate and is persisted on Save, so authors can correct a stub the Director
  # or a relationship proposed with a wrong role before finalizing it.
  def handle_event("toggle_brief", _params, socket),
    do: {:noreply, assign(socket, brief_open: not socket.assigns.brief_open)}

  def handle_event("set_role", %{"role" => role}, socket) do
    {:noreply, socket |> assign(role: role) |> touch()}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      %{current_user: user, entry: %{id: id}} = socket.assigns
      socket = socket |> assign_form(params) |> Autosave.cancel()
      %{name: name, relationships: rels} = socket.assigns

      existing_entries = other_characters(user, id)
      existing = char_names(existing_entries)
      world_bible_id = world_id_int(socket.assigns.world_id)

      # The three things a *deliberate* save does that a timer must not. Seeding stubs
      # writes new people into the library; promotion makes a half-written sheet
      # castable; the reciprocal pass spends a provider call. None of them are decisions
      # the author has made merely by typing, and all three would fire every couple of
      # seconds while they were still mid-sentence.
      stubbed = seed_stubs(rels, existing, name, Owner.of(user), world_bible_id, id)

      # Every relationship that names a real character (existing or just-stubbed) now
      # carries its stable id, so links and context resolve by id, not name.
      rels = resolve_target_ids(rels, existing_entries, stubbed)

      socket =
        socket
        |> assign_relationships(rels)
        |> persist(status: :full)
        |> assign_characters(other_characters(user, id))
        |> assign_relationships(rels)
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
       |> Generating.request("all", "autofill.all", %{
         kind: :character,
         brief: brief,
         current: current,
         opts: opts
       })}
    end)
  end

  def handle_event("generate_field", %{"field" => f}, socket) when f in @block_fields do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request(f, "autofill.field", %{
         kind: :character,
         field: f,
         current: current,
         opts: opts
       })}
    end)
  end

  def handle_event("expand_field", %{"field" => f}, socket) when f in @block_fields do
    safe(socket, fn ->
      opts = paragraph_opts(socket, f, nil)

      {:noreply,
       socket
       |> Generating.request("#{f}:expand", "autofill.paragraph", %{
         kind: :character,
         field: f,
         opts: opts
       })}
    end)
  end

  def handle_event("generate_block", %{"field" => f, "index" => i}, socket)
      when f in @block_fields do
    idx = String.to_integer(i)

    safe(socket, fn ->
      opts = paragraph_opts(socket, f, idx)

      {:noreply,
       socket
       |> Generating.request("#{f}:#{idx}", "autofill.paragraph", %{
         kind: :character,
         field: f,
         opts: opts
       })}
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
           |> touch()
           |> view_patch(panel: nil)}
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

        _topic ->
          {:noreply,
           socket
           |> assign(boundaries: socket.assigns.boundaries ++ [Boundary.from_map(params)])
           |> touch()
           |> view_patch(panel: nil)}
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
    safe(socket, fn -> {:noreply, suggest_relationships(socket)} end)
  end

  def handle_event("suggest_boundaries", _params, socket) do
    safe(socket, fn -> {:noreply, suggest_boundaries(socket)} end)
  end

  # ── Facts (§6.1) ────────────────────────────────────────────────────────────

  def handle_event("add_fact", params, socket) do
    safe(socket, fn ->
      case String.trim(params["statement"] || "") do
        "" ->
          {:noreply, put_flash(socket, :error, "Write the fact first.")}

        statement ->
          fact = %Fact{statement: statement}

          {:noreply,
           socket
           |> assign(facts: socket.assigns.facts ++ [fact])
           |> touch()
           |> view_patch(panel: nil)}
      end
    end)
  end

  def handle_event("remove_fact", %{"index" => i}, socket) do
    idx = String.to_integer(i)
    {:noreply, socket |> assign(facts: List.delete_at(socket.assigns.facts, idx)) |> touch()}
  end

  # The two flags are independently toggleable because they're independent: always-in-
  # mind is whether she carries it, secret is who else has it.
  def handle_event("toggle_fact", %{"index" => i, "flag" => flag}, socket)
      when flag in ["core", "concealed"] do
    idx = String.to_integer(i)
    key = String.to_existing_atom(flag)

    facts =
      List.update_at(socket.assigns.facts, idx, fn f -> Map.put(f, key, !Map.get(f, key)) end)

    {:noreply, socket |> assign(facts: facts) |> touch()}
  end

  def handle_event("suggest_facts", _params, socket) do
    safe(socket, fn ->
      current = current_values(socket)
      opts = [existing: socket.assigns.facts] ++ gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request("facts", "autofill.facts", %{current: current, opts: opts})}
    end)
  end

  # ── Audience (§3.3) ─────────────────────────────────────────────────────────

  # Reachable only from a secret, and the same component the world bible opens — one
  # implementation, two headers, so the two can't drift.
  def handle_event("open_audience", %{"index" => i}, socket),
    do: {:noreply, view_patch(socket, audience: i, panel: nil)}

  def handle_event("close_audience", _params, socket),
    do: {:noreply, view_patch(socket, audience: nil)}

  def handle_event("toggle_audience", %{"kind" => kind, "id" => id}, socket) do
    case socket.assigns.audience_at do
      index when is_integer(index) ->
        facts =
          List.update_at(socket.assigns.facts, index, fn fact ->
            %Fact{fact | audience: toggle(fact.audience, kind, id)}
          end)

        {:noreply, socket |> assign(facts: facts) |> touch()}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Cover (§2.12) ───────────────────────────────────────────────────────────

  # Written from the whole sheet, secrets included, under instruction to give none of
  # them away — and `Cover` refuses a draft that quotes one rather than handing back a
  # blurb that spoils. That refusal is surfaced as an error, not silently retried
  # again: the author should know the model kept reaching for the secret.
  def handle_event("generate_cover", _params, socket) do
    safe(socket, fn ->
      sheet = draft_sheet(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request("cover", "cover", %{subject: sheet, opts: opts})}
    end)
  end

  # ── Tier (§2.5) ─────────────────────────────────────────────────────────────

  # Saved immediately rather than with the form. Tier is a property of the campaign's
  # shape rather than of the prose, the control is a set of pills with no obvious
  # "apply", and a half-saved cast list is worse than an eagerly-saved one.
  def handle_event("set_tier", %{"tier" => tier}, socket) do
    safe(socket, fn ->
      tier = String.to_existing_atom(tier)

      case Characters.set_tier(socket.assigns.entry.id, tier) do
        {:ok, entry} ->
          {:noreply, assign(socket, tier: tier, entry: entry)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "That isn't a cast tier.")}
      end
    end)
  end

  # ── Groups ──────────────────────────────────────────────────────────────────

  def handle_event("join_group", %{"group_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("join_group", %{"group_id" => group_id}, socket) do
    safe(socket, fn ->
      # Joining writes to the group, and membership is what resolves an audience — so
      # an unchecked id here is a way to put your own character inside somebody else's
      # secret.
      if Permissions.can_edit?(Library.get(group_id), socket.assigns.current_user) do
        {:ok, _} = Groups.add_member(group_id, socket.assigns.entry.id)
        {:noreply, socket |> reload_groups() |> view_patch(panel: nil)}
      else
        {:noreply, put_flash(socket, :error, "That group isn't yours.")}
      end
    end)
  end

  def handle_event("leave_group", %{"group_id" => group_id}, socket) do
    safe(socket, fn ->
      {:ok, _} = Groups.remove_member(group_id, socket.assigns.entry.id)
      {:noreply, reload_groups(socket)}
    end)
  end

  # ── Info drawers ────────────────────────────────────────────────────────────

  # One drawer per section, never one popover per setting: the concepts in a section
  # only make sense together (`ux/polyphony-character.html` §06b). Toggling the open
  # one shut is what the × does, so both use this event.
  def handle_event("drawer", %{"section" => section}, socket) do
    {:noreply,
     view_patch(socket, drawer: if(socket.assigns.drawer == section, do: nil, else: section))}
  end

  # ── Add panels ──────────────────────────────────────────────────────────────

  # Adding to a list opens a panel below the sheet rather than an inline form. Two
  # reasons, and they agree: the mock does it that way (§04 "Adding someone who
  # doesn't exist" is its own sheet), and it keeps the lists inside the sheet's one
  # form without nesting a second one inside it.
  def handle_event("panel", %{"panel" => panel}, socket) do
    {:noreply,
     view_patch(socket,
       panel: if(panel == "" or socket.assigns.panel == panel, do: nil, else: panel)
     )}
  end

  defp reload_groups(socket) do
    owner = Owner.of(socket.assigns.current_user)

    assign(socket,
      groups: Groups.for_character(owner, socket.assigns.entry.id),
      all_groups: Groups.list(owner)
    )
  end

  defp suggest_relationships(socket) do
    current = current_values(socket)
    opts = [existing: socket.assigns.relationships] ++ gen_opts(socket)

    socket
    |> Generating.request("relationships", "autofill.relationships", %{
      current: current,
      opts: opts
    })
  end

  defp suggest_boundaries(socket) do
    current = current_values(socket)
    opts = [existing: socket.assigns.boundaries] ++ gen_opts(socket)

    socket
    |> Generating.request("boundaries", "autofill.boundaries", %{current: current, opts: opts})
  end

  # Auto-suggest on generate-all only when the card is empty — never clobber authored ones.
  defp maybe_suggest_relationships(socket) do
    if socket.assigns.relationships == [], do: suggest_relationships(socket), else: socket
  end

  defp maybe_suggest_boundaries(socket) do
    if socket.assigns.boundaries == [], do: suggest_boundaries(socket), else: socket
  end

  # Only onto an empty list, like the two above: generate-all drafts a fresh sheet, and
  # appending to facts somebody has already written and marked would be a second author
  # rather than a first draft. Everything arrives public — concealment is the author's
  # decision, taken one fact at a time from its own menu.
  defp put_generated_facts(socket, nil), do: socket

  defp put_generated_facts(%{assigns: %{facts: [_ | _]}} = socket, _lines), do: socket

  defp put_generated_facts(socket, lines) do
    facts =
      for statement <-
            List.wrap(if(is_binary(lines), do: String.split(lines, "\n"), else: lines)),
          is_binary(statement),
          trimmed = String.trim(statement),
          trimmed != "",
          do: %Fact{statement: trimmed}

    if facts == [], do: socket, else: assign(socket, facts: facts)
  end

  # ── Generation results ────────────────────────────────────────────────────────
  #
  # The same bodies the `handle_async` clauses had. The screen still decides what a
  # result *means* — Generate-all fills only empty cards, a suggestion appends, a leaked
  # cover is refused — because that is the part worth having in one place. What moved is
  # where the provider call ran (`Polyphony.Generations`), so an answer that arrives
  # after the tab closed is applied on the next mount instead of thrown away.

  def handle_info({:generation, "all", {:ok, values}}, socket) do
    blocks =
      Enum.reduce(values, socket.assigns.blocks, fn {f, v}, acc ->
        if f in @block_fields, do: Map.put(acc, f, to_blocks(v)), else: acc
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]

    # "Generate all fields" also fills facts, relationships and boundaries when they're
    # empty (a fresh character), so one click drafts the whole sheet. Existing ones are
    # left alone — the author can top them up with each card's ✨ Suggest.
    {:noreply,
     socket
     |> assign(name: name, blocks: blocks)
     |> put_generated_facts(values["facts"])
     |> mark("all", false)
     |> touch()
     |> maybe_suggest_relationships()
     |> maybe_suggest_boundaries()}
  end

  def handle_info({:generation, "cover", {:ok, cover}}, socket) do
    {:noreply, socket |> assign(cover: cover) |> mark("cover", false) |> touch()}
  end

  # The leak refusal gets its own message. "Generation failed: :leaked" would read as
  # a broken feature; what actually happened is that the cover kept quoting a secret
  # and was thrown away on purpose.
  def handle_info({:generation, "cover", {:error, :leaked}}, socket) do
    {:noreply,
     socket
     |> mark("cover", false)
     |> put_flash(
       :error,
       "The cover kept giving away a secret, so it wasn't kept. Try again, or write it yourself."
     )}
  end

  def handle_info({:generation, "boundaries", {:ok, suggestions}}, socket) do
    socket = mark(socket, "boundaries", false)

    case suggestions do
      [] ->
        {:noreply, put_flash(socket, :info, "No boundaries suggested.")}

      list ->
        boundaries = Enum.map(list, &Boundary.from_map/1)

        {:noreply,
         socket
         |> assign(boundaries: socket.assigns.boundaries ++ boundaries)
         |> touch()
         |> put_flash(
           :info,
           "Added #{length(boundaries)} suggested boundary(ies). Review and Save."
         )}
    end
  end

  def handle_info({:generation, "relationships", {:ok, suggestions}}, socket) do
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

  def handle_info({:generation, "facts", {:ok, suggestions}}, socket) do
    socket = mark(socket, "facts", false)

    case suggestions do
      [] ->
        {:noreply, put_flash(socket, :info, "No new facts suggested.")}

      list ->
        facts =
          Enum.map(list, fn f ->
            %Fact{statement: f["statement"], core: f["core"], concealed: f["concealed"]}
          end)

        {:noreply,
         socket
         |> assign(facts: socket.assigns.facts ++ facts)
         |> touch()
         |> put_flash(:info, "Added #{length(facts)} suggested fact(s). Review and Save.")}
    end
  end

  # Reciprocal generation is best-effort background enrichment of the just-created
  # stubs — never surfaced as an error. On success, patch each stub's regard toward
  # this character; on failure, the placeholder descriptor stands.
  def handle_info(
        {:generation, "reciprocals", {:ok, {stubs, self_name, self_id, reciprocals}}},
        socket
      ) do
    for %{id: id, target: target} <- stubs, r = reciprocals[target], present_string?(r) do
      patch_stub_reciprocal(id, self_name, self_id, r)
    end

    {:noreply, mark(socket, "reciprocals", false)}
  end

  def handle_info({:generation, "reciprocals", result}, socket) do
    Logger.warning("[authoring] reciprocal generation skipped: #{inspect(result)}")
    {:noreply, mark(socket, "reciprocals", false)}
  end

  def handle_info({:generation, f, {:ok, value}}, socket) when f in @block_fields do
    {:noreply, socket |> put_blocks(f, to_blocks(value)) |> mark(f, false) |> touch()}
  end

  # A paragraph: appended to a field (`"voice:expand"`) or replacing one block of it
  # (`"voice:2"`). One operation, two keys — they differ only in where it goes.
  def handle_info({:generation, key, {:ok, para}}, socket) do
    case String.split(key, ":", parts: 2) do
      [f, "expand"] when f in @block_fields ->
        blocks = append_paragraph(socket.assigns.blocks[f], para)
        {:noreply, socket |> put_blocks(f, blocks) |> mark(key, false) |> touch()}

      [f, index] when f in @block_fields ->
        blocks = List.replace_at(socket.assigns.blocks[f], String.to_integer(index), para)
        {:noreply, socket |> put_blocks(f, blocks) |> mark(key, false) |> touch()}

      _ ->
        {:noreply, mark(socket, key, false)}
    end
  end

  def handle_info({:generation, key, result}, socket),
    do: {:noreply, gen_failed(socket, key, result)}

  # The quiet write: the sheet exactly as it stands, and nothing more. Deliberately
  # narrower than Save — see the note there.
  def handle_info(:autosave, socket), do: {:noreply, persist(socket, [])}

  def terminate(_reason, socket), do: Autosave.flush(socket, &persist(&1, []))

  defp persist(socket, opts) do
    %{entry: %{id: id}, blocks: blocks} = socket.assigns

    sheet = %CharacterSheet{
      socket.assigns.sheet
      | name: socket.assigns.name,
        pronouns: blank_to_nil(socket.assigns.pronouns),
        role: blank_to_nil(socket.assigns.role),
        cover: blank_to_nil(socket.assigns.cover),
        tier: socket.assigns.tier,
        premise: join_blocks(blocks["premise"]),
        appearance: join_blocks(blocks["appearance"]),
        voice: join_blocks(blocks["voice"]),
        temperament: join_blocks(blocks["temperament"]),
        backstory: join_blocks(blocks["backstory"]),
        world_bible_id: world_id_int(socket.assigns.world_id),
        relationships: socket.assigns.relationships,
        boundaries: socket.assigns.boundaries,
        facts: socket.assigns.facts,
        # Promotion is Save's, not the timer's: a stub becomes castable because the
        # author reviewed it and said so, and `SceneControl` is entitled to read that
        # as a decision rather than as evidence that a key was pressed.
        status: Keyword.get(opts, :status, socket.assigns.sheet.status)
    }

    {:ok, entry} = Library.update_payload(id, sheet)

    socket
    |> assign(
      entry: entry,
      sheet: sheet,
      name: sheet.name || "",
      pronouns: sheet.pronouns || "",
      blocks: blocks_from_sheet(sheet)
    )
    |> Autosave.saved()
  end

  defp touch(socket), do: Autosave.touch(socket)

  defp assign_form(socket, params) do
    name = params["name"] || socket.assigns.name
    pronouns = params["pronouns"] || socket.assigns.pronouns
    cover = params["cover"] || socket.assigns.cover

    blocks =
      Map.new(@block_fields, fn f ->
        {f, param_blocks(params["b_#{f}"], socket.assigns.blocks[f])}
      end)

    assign(socket, name: name, pronouns: pronouns, cover: cover, blocks: blocks)
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

  # The sheet as it stands in the form, unsaved edits included. The cover has to be
  # written from what the author is looking at, not from what was last persisted.
  defp draft_sheet(socket) do
    %{blocks: blocks} = socket.assigns

    %CharacterSheet{
      socket.assigns.sheet
      | name: socket.assigns.name,
        pronouns: blank_to_nil(socket.assigns.pronouns),
        premise: join_blocks(blocks["premise"]),
        appearance: join_blocks(blocks["appearance"]),
        voice: join_blocks(blocks["voice"]),
        temperament: join_blocks(blocks["temperament"]),
        backstory: join_blocks(blocks["backstory"]),
        facts: socket.assigns.facts
    }
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

  defp toggle(audience, "group", id), do: Audience.toggle_group(Audience.from(audience), id)

  defp toggle(audience, _character, id),
    do: Audience.toggle_character(Audience.from(audience), id)

  # Everyone this author has written, for the picker. The character the sheet is about
  # is excluded from the list and passed as the owner instead — they always know their
  # own secrets, so it is never a choice.
  defp assign_audience_sources(socket) do
    owner = Owner.of(socket.assigns.current_user)
    self_id = to_string(socket.assigns.entry.id)
    characters = Enum.reject(Characters.list(owner), &(to_string(&1.id) == self_id))
    groups = Groups.list(owner)

    people =
      Enum.map(characters, fn c ->
        {to_string(c.id), char_name(c) || "Unnamed", Characters.tier_of(c),
         AudiencePicker.colour(Library.payload(c))}
      end)

    assign(socket,
      picker_groups: Enum.map(groups, &{to_string(&1.id), group_name(&1), group_note(&1)}),
      picker_people: people,
      picker_labels:
        Map.new(
          Enum.map(groups, &{to_string(&1.id), group_name(&1)}) ++
            Enum.map(characters, &{to_string(&1.id), char_name(&1) || "Unnamed"})
        )
    )
  end

  defp group_note(entry) do
    case length(Groups.member_ids(entry.id)) do
      0 -> {:empty, 0}
      n -> {:count, n}
    end
  end

  # The other direction (§04): what *this* character starts out knowing, gathered from
  # everyone else's secrets and every world they're written against.
  #
  # A **read-only projection**, derived on each load rather than stored — one fact, one
  # home, so the two directions cannot drift. To change who knows something you change
  # it where the secret lives, which is why each line offers a way there.
  defp assign_knows(socket) do
    owner = Owner.of(socket.assigns.current_user)
    me = to_string(socket.assigns.entry.id)

    sources =
      for entry <- Library.list_for_owner(owner),
          entry.kind in ["character", "world_bible"],
          to_string(entry.id) != me,
          source = knowledge_source(entry),
          do: source

    assign(socket, knows: Audience.known_by(me, sources))
  end

  defp knowledge_source(entry) do
    case Library.payload(entry) do
      %CharacterSheet{name: name, facts: facts} ->
        {name || "Someone", entry.id, facts || []}

      %WorldBible{name: name} = bible ->
        {name || "A world", nil,
         WorldBible.entries(bible.rules) ++ WorldBible.entries(bible.starting_canon)}

      _ ->
        nil
    end
  end

  # ── Assign / block helpers ────────────────────────────────────────────────────

  # Mark the form as having unsaved edits (hides the ✓ indicator, arms the
  # leave-confirmation on navigation links).
  defp mark(socket, key, on?), do: Generating.mark(socket, key, on?)

  # Blank enough that leading with the brief is the helpful thing rather than clutter.
  # The prose is what "written" means here — a name alone is a stub somebody hasn't
  # started, which is exactly when the one-line path should be open.
  defp empty_sheet?(assigns) do
    Enum.all?(@block_fields, &(join_blocks(assigns.blocks[&1]) == "")) and
      assigns.facts == [] and assigns.relationships == []
  end

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

      # Into the same campaign as the character who named them. A person written out of
      # somebody's relationship belongs to that somebody's story — and a stub in no
      # campaign is one the roster, the "fill them in" prompt and the library's own
      # grouping all fail to see.
      Campaigns.cast(Campaigns.of_character(owner, self_id), entry.id)

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

    Generating.request(socket, "reciprocals", "autofill.reciprocals", %{
      source: source,
      pairs: pairs,
      stubs: stubs,
      self_name: self_name,
      self_id: self_id,
      opts: opts
    })
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
    do:
      assign(socket,
        char_names: char_names(entries),
        char_links: char_links(entries),
        char_hues: char_hues(entries)
      )

  # Voice colours for the relationship list, keyed both ways — by stable id for a
  # linked relationship, by lowercased name for one that hasn't been resolved yet.
  # The kit's rule is that a character is the same hue everywhere they appear.
  defp char_hues(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      colour = Voice.of_sheet(Library.payload(entry))

      case char_name(entry) do
        nil -> Map.put(acc, entry.id, colour)
        name -> acc |> Map.put(entry.id, colour) |> Map.put(String.downcase(name), colour)
      end
    end)
  end

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
          # The world as this character may know it — generation grounded in a secret
          # would write a character who knows it.
          "rules" => Enum.join(WorldBible.public(wb.rules), "\n"),
          "starting_canon" => Enum.join(WorldBible.public(wb.starting_canon), "\n")
        }
    end
  end

  def render(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header
        title={header_title(@name)}
        eyebrow={@world_context && @world_context["name"]}
        back={~p"/library"}
        back_label="Back to library"
        back_confirm={leave_confirm(@dirty)}
      >
        <:actions>
          <Kit.pill :if={@sheet.status != :full} colour="var(--lamp)">Pending</Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- The identity line: who they are at a glance, in the order a reader needs
            it. Tier carries an info affordance because "Main cast" is the mock's own
            example of a label that means something a first-time reader wouldn't
            assume — it secretly means context residency. --%>
      <Kit.row class="px-4 py-3 flex items-start gap-3" style="background:var(--b2)">
        <span class="w-11 h-11 rounded-xl shrink-0" style={"background:#{Voice.of_sheet(@sheet)}"}></span>
        <div class="min-w-0 flex-1">
          <div class="ttl text-[18px] truncate font-semibold"><%= header_title(@name) %></div>
          <div class="flex flex-wrap items-center gap-1.5 mt-1">
            <Kit.pill>
              <%= CharacterSheet.tier_label(@tier) %>
              <Kit.info label="cast tiers" phx-click="drawer" phx-value-section="tier" />
            </Kit.pill>
            <Kit.pill :if={@pronouns != ""}><%= @pronouns %></Kit.pill>
            <Kit.pill :if={@world_context}><%= @world_context["name"] %></Kit.pill>
            <Kit.pill><%= scene_line(@scene_count) %></Kit.pill>
          </div>
        </div>
      </Kit.row>

      <Kit.jump class="shrink-0">
        <:stop :for={{id, label} <- stops()}>
          <a href={"##{id}"}><%= label %></a>
        </:stop>
      </Kit.jump>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <.drawer :if={@drawer == "tier"} section="tier" title="About cast tiers">
          <:part colour="var(--lamp)" name="Main cast">
            Always in context. The people the story is about.
          </:part>
          <:part colour="var(--v2)" name="Recurring">
            Also always in context — a side character who should remember and be remembered.
          </:part>
          <:part colour="var(--bcm)" name="Walk-ons">
            Loaded only for the scenes they appear in. A walk-on who turns out to matter
            gets promoted; one who has served their purpose gets demoted rather than deleted.
          </:part>
        </.drawer>

        <%!-- One brief writes everything, above the sheet rather than buried in it.
              It was several screens down, under the fields it fills — which is the
              wrong way round on a blank character: the whole point is that you don't
              have to start with the fields. The world bible and the mock's own
              new-character flow (§02, "✦ Write her sheet") both lead with it, and it
              folds away once there is a sheet here, like the campaign's Quick Build. --%>
        <Kit.sheet
          :if={@brief_open or empty_sheet?(assigns)}
          class="m-4"
          style={empty_sheet?(assigns) && "border-color:var(--lamp)"}
        >
          <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="ttl text-[15px] font-semibold">Who are they, in a line</span>
            <button
              :if={not empty_sheet?(assigns)}
              type="button"
              class="dim text-[17px] leading-none"
              phx-click="toggle_brief"
              aria-label="Close"
            >
              ×
            </button>
          </Kit.row>
          <div class="px-4 py-3">
            <form id="sheet-generate-all" phx-submit="generate_all">
              <label for="brief" class="sr-only">Describe the character</label>
              <textarea
                id="brief"
                name="brief"
                rows="2"
                placeholder="A jaded harbour-town detective who used to be a priest and still prays out of habit."
                class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2"
              ></textarea>
              <Kit.btn kind={:primary} type="submit" disabled={busy?(@generating, "all")}>
                <%= if busy?(@generating, "all"), do: "✦ Writing…", else: "✦ Write every field" %>
              </Kit.btn>
            </form>
            <p class="text-[11px] leading-relaxed dim mt-2">
              Builds on anything already written rather than replacing it.
            </p>
          </div>
        </Kit.sheet>

        <div :if={not @brief_open and not empty_sheet?(assigns)} class="px-4 pt-4">
          <Kit.btn size={:sm} type="button" phx-click="toggle_brief">✦ Write it from a line</Kit.btn>
        </div>

        <%!-- One form owns everything the sheet stores: the cover, the five prose
              fields, and the name and pronouns in its footer. The list sections below
              it are read-and-toggle only — adding to one opens a panel *outside* this
              form, because a form inside a form isn't a thing, and because the mock
              puts adding in its own sheet anyway (§02, §04). --%>
        <form id="sheet-form" phx-submit="save" phx-change="sync">
        <Kit.sheet class="m-4">
          <%!-- ── Cover ───────────────────────────────────────────────────── --%>
          <div class="row px-4 py-3" id="cover">
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">Cover</span>
                <Kit.info label="the cover" phx-click="drawer" phx-value-section="cover" />
              </span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="generate_cover"
                disabled={busy?(@generating, "cover")}
              >
                <%= if busy?(@generating, "cover"), do: "✦ …", else: "✦ Rewrite" %>
              </Kit.btn>
            </div>
            <label for="cover-text" class="sr-only">Cover</label>
            <%!-- Written from everything below it, so it is the slowest ✦ on the screen
                  and the one most worth drawing. An existing cover stays on the page
                  while the new one is written — it is still the true cover until the
                  replacement lands. --%>
            <Kit.skel_lines
              :if={busy?(@generating, "cover") and blank_cover?(@cover)}
              lines={["100%", "95%", "48%"]}
              label="Writing the cover"
            />
            <textarea
              :if={not (busy?(@generating, "cover") and blank_cover?(@cover))}
              id="cover-text"
              name="cover"
              rows="3"
              phx-debounce="600"
              class="field px-3 py-2.5 text-[13px] leading-relaxed w-full"
              placeholder="The only part strangers see."
            ><%= @cover %></textarea>
            <Kit.skel_lines
              :if={busy?(@generating, "cover") and not blank_cover?(@cover)}
              class="mt-1.5"
              lines={["92%", "56%"]}
              label="Writing a new cover"
            />
            <p class="text-[11px] dim mt-1.5">The only part strangers see.</p>
          </div>

          <.drawer :if={@drawer == "cover"} section="cover" title="About the cover">
            <:intro>
              A short blurb someone reads before they decide to take this character on.
              It's written from everything below it — the secrets included — under
              instruction to give none of them away.
            </:intro>
            <:part colour="var(--secret)" name="It knows the secrets">
              That's what stops it reading like a stranger wrote it. If a draft quotes one,
              it's thrown away rather than shown to you.
            </:part>
          </.drawer>

          <%!-- ── The five written fields ─────────────────────────────────── --%>
          <.block_field
            :for={{f, label} <- field_specs()}
            id={f}
            field={f}
            label={label}
            blocks={@blocks[f]}
            generating={@generating}
          />

          <%!-- ── Facts ───────────────────────────────────────────────────── --%>
          <div class="row px-4 py-3" id="facts">
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">What's true about them</span>
                <Kit.info label="facts" phx-click="drawer" phx-value-section="facts" />
              </span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="suggest_facts"
                disabled={busy?(@generating, "facts")}
              >
                <%= if busy?(@generating, "facts"), do: "✦ …", else: "✦ Suggest" %>
              </Kit.btn>
            </div>

            <p :if={@facts == [] and not suggesting_facts?(assigns)} class="text-[13px] dim">
              Nothing yet. Facts are the flat statements they'd never contradict.
            </p>

            <%!-- Suggestions arrive as a batch of rows, so the wait is drawn as rows.
                  "✦ Write every field" writes facts too, which is why "all" counts. --%>
            <Kit.skel_lines
              :if={suggesting_facts?(assigns)}
              class="mb-2"
              lines={["86%", "70%", "78%"]}
              label="Suggesting facts"
            />

            <.fact_row
              :for={{f, i} <- Enum.with_index(@facts)}
              fact={f}
              index={i}
              labels={@picker_labels}
            />

            <.add_row label="Add something that's true…" panel="fact" />
          </div>

          <.drawer :if={@drawer == "facts"} section="facts" title="About facts">
            <:intro>
              Short, flat statements that are true about them. They're what they'd never
              contradict, so keep them to things you'd defend rather than things you'd like.
            </:intro>
            <:part colour="var(--lamp)" name="Always in mind">
              In front of them for every turn, in every scene. Everything else is remembered
              when it's relevant — they still know it, it's just fetched rather than carried.
              A few is right.
            </:part>
            <:part colour="var(--secret)" name="Secret">
              Nobody starts out knowing it. Everyone else finds out in play, if they ever do —
              and the two settings are independent, so they can have a secret they rarely
              think about.
            </:part>
          </.drawer>

          <%!-- ── What they start out knowing (§04) ───────────────────────── --%>
          <%!-- The other direction, and read-only on purpose: one fact, one home, so
                nothing can drift out of sync. Each line says where it came from, so
                an inherited one is obvious, and offers the way to where it's edited. --%>
          <div :if={@knows != []} class="row px-4 py-3" id="knows-secrets">
            <div class="lbl dim mb-2">What they start out knowing</div>
            <div :for={k <- @knows} class="py-2">
              <p class="text-[13px] leading-relaxed"><%= k.statement %></p>
              <div class="lbl dim mt-1"><%= knows_provenance(k) %></div>
            </div>
            <p class="text-[11px] leading-relaxed dim mt-1.5">
              To change who knows something, change it where the secret lives. There's
              only ever one copy.
            </p>
          </div>

          <%!-- ── Relationships ───────────────────────────────────────────── --%>
          <div class="row px-4 py-3" id="knows">
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">Who they know</span>
                <Kit.info label="relationships" phx-click="drawer" phx-value-section="knows" />
              </span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="suggest_relationships"
                disabled={busy?(@generating, "relationships")}
              >
                <%= if busy?(@generating, "relationships"), do: "✦ …", else: "✦ Suggest" %>
              </Kit.btn>
            </div>

            <p
              :if={@relationships == [] and not busy?(@generating, "relationships")}
              class="text-[13px] dim"
            >
              Nobody yet. A name that doesn't exist becomes a walk-on when you save.
            </p>

            <Kit.skel_lines
              :if={busy?(@generating, "relationships")}
              class="mb-2"
              lines={["74%", "88%", "66%"]}
              label="Suggesting who they know"
            />

            <div :for={{r, i, colour} <- rel_rows(@relationships, @char_hues)} class="py-2.5">
              <div class="flex items-center gap-2.5 mb-1">
                <span class="av" style={"background:#{colour}"}></span>
                <span class="text-[13.5px] font-semibold flex-1 min-w-0 truncate">
                  <.rel_target
                    target={r.target}
                    target_id={r.target_id}
                    links={@char_links}
                    confirm={leave_confirm(@dirty)}
                  />
                </span>
                <Kit.btn
                  size={:sm}
                  kind={:pen}
                  type="button"
                  phx-click="remove_relationship"
                  phx-value-index={i}
                >
                  Remove
                </Kit.btn>
              </div>
              <p :if={present_string?(r.descriptor)} class="text-[13px] leading-relaxed">
                <%= r.descriptor %>
              </p>
              <%!-- Both directions are shown because the interesting cases are the
                    lopsided ones: asymmetry should look deliberate, not forgotten. --%>
              <div
                :if={present_string?(r.reciprocal)}
                class="flex items-start gap-2 mt-2 pt-2"
                style="border-top:1px solid var(--rule)"
              >
                <span class="lbl dim shrink-0 pt-0.5">Back →</span>
                <p class="text-[12.5px] leading-relaxed dim"><%= r.reciprocal %></p>
              </div>
            </div>

            <.add_row label="Add someone they know…" panel="relationship" />
          </div>

          <.drawer :if={@drawer == "knows"} section="knows" title="About who they know">
            <:intro>
              How <em>they</em> regard someone else — directional, and often lopsided. The
              interesting cases are where the two directions don't match.
            </:intro>
            <:part colour="var(--bcm)" name="A name nobody has yet">
              Joins the campaign as a walk-on and stays unwritten until someone needs them.
              That's what stops the whole cast writing itself sideways from one button.
            </:part>
          </.drawer>

          <%!-- ── Pressures: two lists, never one ─────────────────────────── --%>
          <div id="pushed">
            <.pressure_list
              :for={direction <- Boundary.directions()}
              direction={direction}
              boundaries={@boundaries}
              generating={@generating}
            />

            <div class="row px-4 py-3">
              <.add_row label="Add something…" panel="pressure" />
            </div>
          </div>

          <.drawer :if={@drawer == "pushed"} section="pushed" title="About being pushed">
            <:intro>
              These are played, not filtered. A line they hold is a scene beat — something
              the story has to work against, and something that can give at the right moment.
            </:intro>
            <:part colour="var(--pencil)" name="Won't, and can't stop">
              Two directions. What they refuse, and what they do whether or not they mean to.
              Both can be absolute or can turn once.
            </:part>
            <:part colour="var(--lamp)" name="Until, and then">
              What has to happen before it turns, and what they're like afterwards. They
              aren't told the second one until it's true of them.
            </:part>
            <:part colour="var(--bcm)" name="Flagging mature content">
              Only if the item is about it. A flagged one stays closed in campaigns that
              don't allow that content — and for something they can't stop, closed means
              they don't do it. The ceiling always pushes toward refusal.
            </:part>
          </.drawer>

          <%!-- ── Groups ──────────────────────────────────────────────────── --%>
          <div class="px-4 py-3" id="groups">
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="flex items-center gap-1.5">
                <span class="lbl dim">Groups they belong to</span>
                <Kit.info label="groups" phx-click="drawer" phx-value-section="groups" />
              </span>
            </div>

            <p :if={@groups == []} class="text-[13px] dim">Nobody has a claim on them yet.</p>

            <div :for={g <- @groups} class="flex items-center gap-2.5 py-2">
              <span class="av" style={"background:#{group_hue(g)}"}></span>
              <div class="min-w-0 flex-1">
                <div class="text-[13px] font-semibold"><%= group_name(g) %></div>
                <div class="text-[11px] dim">Member</div>
              </div>
              <Kit.btn
                size={:sm}
                kind={:pen}
                type="button"
                phx-click="leave_group"
                phx-value-group_id={g.id}
              >
                Remove
              </Kit.btn>
            </div>

            <.add_row
              :if={joinable(@all_groups, @groups) != []}
              label="Add a group…"
              panel="group"
            />
          </div>

          <%!-- ── Name, pronouns, save ────────────────────────────────────── --%>
          <div class="px-4 py-3 flex items-center gap-2 flex-wrap" style="background:var(--b2)">
            <label for="sheet-name" class="sr-only">Name</label>
            <input
              id="sheet-name"
              type="text"
              name="name"
              value={@name}
              phx-debounce="600"
              placeholder="Their name"
              class="field px-3 py-2 text-[13px] flex-1 min-w-0"
            />
            <%!-- Free text, never a menu: the set isn't closed, and a fixed list would
                  be a decision about people rather than about data. --%>
            <label for="sheet-pronouns" class="sr-only">Pronouns</label>
            <input
              id="sheet-pronouns"
              type="text"
              name="pronouns"
              value={@pronouns}
              phx-debounce="600"
              placeholder="she / her"
              class="field px-3 py-2 text-[13px] w-28 shrink-0"
            />
            <Kit.btn kind={:primary} type="submit">Save</Kit.btn>
            <span :if={@saved} class="text-[12px] shrink-0" style="color:var(--ok)" role="status">
              ✓ Saved
            </span>
          </div>
        </Kit.sheet>
        </form>

        <%!-- The shared picker, outside the sheet's form like every other panel. It
              draws itself as a `Kit.overlay` — this sheet is long enough that an
              inline panel opened from a fact halfway down lands off-screen. --%>
        <AudiencePicker.picker
          :if={open_fact(assigns)}
          statement={open_fact(assigns).statement}
          context_label={header_title(@name)}
          audience={open_fact(assigns).audience}
          groups={@picker_groups}
          people={@picker_people}
          owner={to_string(@entry.id)}
          owner_label={header_title(@name)}
          resolved={Audience.resolve(open_fact(assigns).audience, owner: @entry.id)}
        />

        <.fact_panel :if={@panel == "fact"} />
        <.relationship_panel :if={@panel == "relationship"} names={@char_names} />
        <.pressure_panel :if={@panel == "pressure"} />
        <.group_panel :if={@panel == "group"} groups={joinable(@all_groups, @groups)} />

        <.drawer :if={@drawer == "groups"} section="groups" title="About groups">
          <:intro>
            A group is written like a character and used as a starting point for others.
            Joining one and being written from one are different things.
          </:intro>
          <:part colour="var(--secret)" name="Belonging is live">
            It's what a secret addressed to the group resolves against, right now. It works
            for people who were never written from the group at all.
          </:part>
          <:part colour="var(--bcm)" name="Seeding was a copy">
            Whatever they took from the group when they were written is theirs. Editing the
            group later doesn't reach back into them, and joining now doesn't backfill what
            it knows — they'd learn that in a scene.
          </:part>
        </.drawer>

        <%!-- ── Where the sheet is written from, and saved ───────────────── --%>
        <Kit.sheet class="m-4">
          <Kit.row class="px-4 py-3" style="background:var(--b2)">
            <span class="lbl dim">Writing this sheet</span>
          </Kit.row>

          <Kit.row :if={@sheet.status != :full} class="px-4 py-3">
            <p class="text-[13px] leading-relaxed dim mb-2">
              They came out of someone else's relationships and haven't been written yet. Set
              how they fit, fill the fields in — or write them — and save.
            </p>
            <form id="stub-role-form" phx-change="set_role">
              <label for="stub-role" class="lbl dim">How they fit</label>
              <input
                id="stub-role"
                type="text"
                name="role"
                value={@role}
                autocomplete="off"
                phx-debounce="blur"
                placeholder="e.g. estranged mentor, harbour smuggler"
                class="field px-3 py-2 text-[13px] w-full mt-1.5"
              />
            </form>
          </Kit.row>

          <Kit.row class="px-4 py-3">
            <form id="world-select-form" phx-change="select_world">
              <label for="world-select" class="lbl dim">World</label>
              <select
                id="world-select"
                name="world_id"
                class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
              >
                <option value="">— none —</option>
                <option :for={{id, name} <- @worlds} value={id} selected={@world_id == id}>
                  <%= name %>
                </option>
              </select>
              <p class="text-[11px] leading-relaxed dim mt-1.5">
                Grounds everything generated here in a setting.
              </p>
            </form>
          </Kit.row>

          <%!-- Tier saves on tap rather than with the form: it's a property of the
                campaign's shape rather than of the prose, and a set of pills has no
                obvious "apply". --%>
          <Kit.row class="px-4 py-3">
            <span class="lbl dim">They're</span>
            <div class="flex flex-wrap gap-1.5 mt-1.5">
              <button
                :for={t <- CharacterSheet.tiers()}
                type="button"
                class={["pill", t != @tier && "dim"]}
                style={t == @tier && "background:var(--b3)"}
                aria-pressed={to_string(t == @tier)}
                phx-click="set_tier"
                phx-value-tier={t}
              >
                <%= CharacterSheet.tier_label(t) %>
              </button>
            </div>
          </Kit.row>

        </Kit.sheet>
      </div>
    </Kit.frame>
    """
  end

  # ── Section components ────────────────────────────────────────────────────────

  # The "Add …" affordance the mock draws at the foot of every list: a field-shaped
  # row rather than a button, because what follows is a form and this reads as its
  # first line. Tapping it opens the panel below the sheet — the mock's own treatment
  # (§04 "Adding someone who doesn't exist"), and the reason the lists themselves can
  # sit inside the sheet's one form without nesting a second.
  attr(:label, :string, required: true)
  attr(:panel, :string, required: true)

  defp add_row(assigns) do
    ~H"""
    <button
      type="button"
      class="field px-3 py-2 text-[13px] dim w-full text-left mt-2"
      phx-click="panel"
      phx-value-panel={@panel}
    >
      <%= @label %>
    </button>
    """
  end

  # One fact: its statement, its state, and a menu holding its two switches.
  #
  # State and controls are separated because the list is read far more often than it
  # is edited — the flags show as a rule and a chip, and the switches live behind the
  # row's `⋯` (`ux/polyphony-character.html` §03, "item menu · one switch pattern").
  # Same geometry as `Kit.menu`, and `<details>` for the same reason: it opens without
  # a live connection and closes on Escape for free.
  attr(:fact, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:labels, :map, default: %{})

  defp fact_row(assigns) do
    ~H"""
    <%!-- The menu opens **in the flow**. The kit's `.sheet` is `overflow:hidden` — it
          is what rounds the corners — so an absolutely-positioned panel was clipped by
          the sheet's bottom edge, which meant the last facts on a sheet, the ones
          nearest that edge, were the ones whose menus you couldn't read. Same fix and
          same reason as the world bible's lists: this is one control in three places
          (§04) and it must not behave differently in one of them. --%>
    <details class="py-2.5" id={"fact-#{@index}"}>
      <summary class="flex items-start gap-2 list-none cursor-pointer">
        <%!-- Secret owns the left border and always-in-mind is a chip, because only one
              of them can own the structure and a fact can be both. --%>
        <Kit.marked mark={if(@fact.concealed, do: :secret, else: :plain)} class="min-w-0 flex-1">
          <p class="text-[13.5px] leading-relaxed"><%= @fact.statement %></p>
          <div
            :if={@fact.concealed or @fact.core}
            class="flex flex-wrap items-center gap-x-2 gap-y-1 mt-1"
          >
            <%!-- The audience is part of the item, so the count reads without opening
                  anything (§01). --%>
            <AudiencePicker.line :if={@fact.concealed} audience={@fact.audience} labels={@labels} />
            <Kit.chip_core :if={@fact.core} />
          </div>
        </Kit.marked>
        <span class="pill shrink-0" aria-label="Change this fact">⋯</span>
      </summary>

      <nav class="sheet mt-1.5" style="background:var(--b2)">
          <button
            type="button"
            class="row w-full px-4 py-2.5 flex items-center justify-between gap-3 text-left"
            phx-click="toggle_fact"
            phx-value-index={@index}
            phx-value-flag="core"
            aria-pressed={to_string(!!@fact.core)}
          >
            <span>
              <span class="block text-[13px] font-semibold">Always in mind</span>
              <span class="block text-[11px] dim">In front of them every turn</span>
            </span>
            <Kit.sw on={!!@fact.core} colour="var(--lamp)" />
          </button>
          <button
            type="button"
            class="row w-full px-4 py-2.5 flex items-center justify-between gap-3 text-left"
            phx-click="toggle_fact"
            phx-value-index={@index}
            phx-value-flag="concealed"
            aria-pressed={to_string(!!@fact.concealed)}
          >
            <span>
              <span class="block text-[13px] font-semibold">Secret</span>
              <span class="block text-[11px] dim">Nobody else starts out knowing</span>
            </span>
            <Kit.sw on={!!@fact.concealed} colour="var(--secret)" />
          </button>
          <%!-- Secret first, audience second: nothing to point at until it's marked. --%>
          <button
            :if={@fact.concealed}
            type="button"
            class="row w-full px-4 py-2.5 flex items-center justify-between gap-2 text-[13px] text-left"
            phx-click="open_audience"
            phx-value-index={@index}
          >
            <span>Who else knows this</span>
            <span class="dim"><%= knows_count(@fact.audience) %></span>
          </button>
          <button
            type="button"
            class="w-full px-4 py-2.5 text-[13px] text-left"
            style="color:var(--pencil)"
            phx-click="remove_fact"
            phx-value-index={@index}
          >
            Delete
          </button>
      </nav>
    </details>
    """
  end

  # A panel is a sheet with a header, a form, and a way out. Every one of them is the
  # same shape, so the shape lives here and each panel is only its fields.
  attr(:title, :string, required: true)
  attr(:form_id, :string, required: true)
  attr(:submit, :string, required: true)
  attr(:action, :string, default: "Add")
  slot(:inner_block, required: true)
  slot(:note)

  defp panel(assigns) do
    ~H"""
    <Kit.sheet class="mx-4 mb-4">
      <Kit.row class="px-4 py-3 flex items-center justify-between" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold"><%= @title %></span>
        <button
          type="button"
          class="dim text-[17px] leading-none"
          phx-click="panel"
          phx-value-panel=""
          aria-label={"Close #{@title}"}
        >
          ×
        </button>
      </Kit.row>
      <div class="px-4 py-3">
        <form id={@form_id} phx-submit={@submit}>
          <%= render_slot(@inner_block) %>
          <Kit.btn kind={:primary} type="submit" class="mt-1.5"><%= @action %></Kit.btn>
        </form>
        <p :if={@note != []} class="text-[11px] leading-relaxed dim mt-2">
          <%= render_slot(@note) %>
        </p>
      </div>
    </Kit.sheet>
    """
  end

  defp fact_panel(assigns) do
    ~H"""
    <.panel title="Something that's true" form_id="fact-form" submit="add_fact">
      <label for="fact-statement" class="lbl dim">The fact</label>
      <input
        id="fact-statement"
        type="text"
        name="statement"
        autocomplete="off"
        placeholder="She has signed the harbour register every day since she was fourteen."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      />
      <:note>
        Flat and defensible — something they'd never contradict. You can make it always
        in mind, or a secret, once it's on the list.
      </:note>
    </.panel>
    """
  end

  attr(:names, :list, required: true)

  defp relationship_panel(assigns) do
    ~H"""
    <.panel title="Who do they know?" form_id="rel-form" submit="add_relationship">
      <label for="rel-target" class="lbl dim">Their name</label>
      <input
        id="rel-target"
        type="text"
        name="target"
        list="char-names"
        autocomplete="off"
        placeholder="Aldous Ashgrove"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />
      <datalist id="char-names">
        <option :for={n <- @names} value={n}></option>
      </datalist>
      <label for="rel-descriptor" class="lbl dim">How do they regard them?</label>
      <input
        id="rel-descriptor"
        type="text"
        name="descriptor"
        placeholder="The only person on the quay she'd trust with a key."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      />
      <:note>
        A name nobody has yet joins the campaign as a walk-on and stays unwritten until
        someone needs them.
      </:note>
    </.panel>
    """
  end

  defp pressure_panel(assigns) do
    ~H"""
    <.panel title="Where can they be pushed?" form_id="boundary-form" submit="add_boundary">
      <label for="boundary-topic" class="lbl dim">What</label>
      <input
        id="boundary-topic"
        type="text"
        name="topic"
        autocomplete="off"
        placeholder="Name her father"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for="boundary-direction" class="lbl dim">Which way it runs</label>
      <select
        id="boundary-direction"
        name="direction"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      >
        <option value="refusal">Something they won't do</option>
        <option value="compulsion">Something they can't stop doing</option>
      </select>

      <label for="boundary-stance" class="lbl dim">Does anything change that?</label>
      <select
        id="boundary-stance"
        name="stance"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      >
        <option value="closed">Never — whatever happens</option>
        <option value="conditional">Not until…</option>
        <option value="open">No gate at all</option>
      </select>

      <label for="boundary-condition" class="lbl dim">Until</label>
      <input
        id="boundary-condition"
        type="text"
        name="condition"
        placeholder="Someone she loves is going to be hurt by the silence."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for="boundary-after" class="lbl dim">And then</label>
      <input
        id="boundary-after"
        type="text"
        name="after_release"
        placeholder="She says it flatly, in public, and doesn't soften it."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for="boundary-pressure" class="lbl dim">If they're pushed before then</label>
      <input
        id="boundary-pressure"
        type="text"
        name="on_pressure"
        placeholder="She gets very polite, and very boring, and leaves."
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5 mb-3"
      />

      <label for="boundary-category" class="lbl dim">Anything to flag?</label>
      <select
        id="boundary-category"
        name="category"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      >
        <option value="">Nothing — most aren't</option>
        <option value="sexual">Sex</option>
        <option value="graphic_violence">Violence</option>
        <option value="other">Other</option>
      </select>

      <:note>
        <em>And then</em> is written for you, and they aren't told it until it happens.
        Flag mature content only if the item is about it — a campaign that doesn't allow
        it holds this closed either way.
      </:note>
    </.panel>
    """
  end

  attr(:groups, :list, required: true)

  defp group_panel(assigns) do
    ~H"""
    <.panel title="Which group?" form_id="group-form" submit="join_group">
      <label for="group-select" class="lbl dim">The group</label>
      <select
        id="group-select"
        name="group_id"
        class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
      >
        <option :for={g <- @groups} value={g.id}><%= group_name(g) %></option>
      </select>
      <:note>
        Joining is membership and nothing else — they don't quietly gain what the group
        knows. They'd learn that in a scene.
      </:note>
    </.panel>
    """
  end

  # One direction's pressure list. Two lists rather than one is the design's whole
  # argument for this section: direction lives in the grouping, not the wording, so
  # an item can never be read backwards.
  attr(:direction, :atom, required: true)
  attr(:boundaries, :list, required: true)
  attr(:generating, :any, required: true)

  defp pressure_list(assigns) do
    items =
      for {b, i} <- Enum.with_index(assigns.boundaries),
          (b.direction || :refusal) == assigns.direction,
          do: {b, i}

    assigns = assign(assigns, :items, items)

    ~H"""
    <div class="row px-4 py-3">
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="flex items-center gap-1.5">
          <span class="lbl dim"><%= Boundary.direction_label(@direction) %></span>
          <Kit.info
            :if={@direction == :refusal}
            label="being pushed"
            phx-click="drawer"
            phx-value-section="pushed"
          />
        </span>
        <Kit.btn
          :if={@direction == :refusal}
          size={:sm}
          type="button"
          phx-click="suggest_boundaries"
          disabled={busy?(@generating, "boundaries")}
        >
          <%= if busy?(@generating, "boundaries"), do: "✦ …", else: "✦ Suggest" %>
        </Kit.btn>
      </div>

      <p
        :if={@items == [] and not busy?(@generating, "boundaries")}
        class="text-[13px] dim"
      ><%= empty_pressure(@direction) %></p>

      <%!-- One ✦ writes both directions in a single call, so both panes wait together
            and both say so. Silence in one of them would read as that half having
            failed. --%>
      <Kit.skel_lines
        :if={busy?(@generating, "boundaries")}
        class="mb-2"
        lines={["58%", "90%", "72%"]}
        label="Suggesting what they will and won't do"
      />

      <div :for={{b, i} <- @items} class="py-2">
        <Kit.marked mark={if(@direction == :compulsion, do: :compel, else: :bound)}>
          <div class="flex items-center justify-between gap-2 mb-1.5">
            <span class="text-[14px] font-semibold"><%= b.topic %></span>
            <Kit.pill colour={stance_colour(b.stance)} class="shrink-0">
              <%= stance_label(b.stance, @direction) %>
            </Kit.pill>
          </div>
          <div :if={present_string?(b.condition)} class="flex gap-2.5 mb-1">
            <span class="lbl dim shrink-0 pt-0.5 w-14">until</span>
            <span class="text-[13px] leading-relaxed flex-1"><%= b.condition %></span>
          </div>
          <%!-- Shown to the author, never to the character until it's true of them —
                that withholding is `Polyphony.Context`'s job, not this screen's. --%>
          <div :if={present_string?(b.after_release)} class="flex gap-2.5 mb-1">
            <span class="lbl dim shrink-0 pt-0.5 w-14"><%= after_label(@direction) %></span>
            <span class="text-[13px] leading-relaxed flex-1 dim"><%= b.after_release %></span>
          </div>
          <div :if={present_string?(b.on_pressure)} class="flex gap-2.5">
            <span class="lbl dim shrink-0 pt-0.5 w-14"><%= pressure_label(@direction) %></span>
            <span class="text-[13px] leading-relaxed flex-1 dim"><%= b.on_pressure %></span>
          </div>
          <div :if={b.category} class="flex items-center gap-1.5 mt-2">
            <Kit.dot colour="var(--pencil)" />
            <span class="text-[12px] dim">
              Flagged as <%= category_label(b.category) %> — a campaign that doesn't allow it
              holds this closed, whatever the story does.
            </span>
          </div>
        </Kit.marked>
        <Kit.btn
          size={:sm}
          kind={:pen}
          type="button"
          class="mt-1.5"
          phx-click="remove_boundary"
          phx-value-index={i}
        >
          Remove
        </Kit.btn>
      </div>
    </div>
    """
  end

  # The one info drawer, used by every section (`ux/polyphony-character.html` §06b):
  # title, prose, then a subsection per concept with its own status dot. It is the
  # kit's sheet-and-rows applied to explanation rather than a new component — and
  # there is one per *section*, not one per setting, because the concepts in a
  # section only make sense together.
  attr(:title, :string, required: true)
  attr(:section, :string, required: true)
  slot(:intro)

  slot :part do
    attr(:colour, :string)
    attr(:name, :string)
  end

  defp drawer(assigns) do
    ~H"""
    <Kit.sheet class="mx-4 mt-4">
      <Kit.row class="px-4 py-3 flex items-center justify-between" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold"><%= @title %></span>
        <button
          type="button"
          class="dim text-[17px] leading-none"
          phx-click="drawer"
          phx-value-section={@section}
          aria-label={"Close #{@title}"}
        >
          ×
        </button>
      </Kit.row>
      <Kit.row :if={@intro != []} class="px-4 py-3">
        <p class="text-[13px] leading-relaxed"><%= render_slot(@intro) %></p>
      </Kit.row>
      <div :for={{p, i} <- Enum.with_index(@part)} class={i < length(@part) - 1 && "row"}>
        <div class="px-4 py-3">
          <div class="flex items-center gap-1.5 mb-1">
            <Kit.dot colour={p[:colour] || "var(--bcm)"} />
            <span class="text-[13px] font-semibold"><%= p[:name] %></span>
          </div>
          <p class="text-[13px] leading-relaxed"><%= render_slot(p) %></p>
        </div>
      </div>
    </Kit.sheet>
    """
  end

  # `@cover` is nil on a sheet that has never had one.
  defp blank_cover?(cover), do: String.trim(to_string(cover)) == ""

  # Facts arrive from their own ✦ and from "✦ Write every field", which writes them
  # too — a wait the facts section had no way to show.
  defp suggesting_facts?(assigns),
    do: busy?(assigns.generating, "facts") or busy?(assigns.generating, "all")

  # ── Render helpers ────────────────────────────────────────────────────────────

  # The fact whose audience is open, if any.
  defp open_fact(%{audience_at: index} = assigns) when is_integer(index),
    do: Enum.at(assigns.facts, index)

  defp open_fact(_assigns), do: nil

  # The owner is always in it, so the count never reads as nobody on a fact that is
  # at minimum known to the person it's about.
  defp knows_count(audience) do
    case length(Audience.named(Audience.from(audience))) +
           length(Audience.from(audience).group_ids) do
      0 -> "nobody else"
      n -> to_string(n)
    end
  end

  defp knows_provenance(%{from: from, why: :group}), do: "From #{from} · they're in a group"
  defp knows_provenance(%{from: from, why: _named}), do: "From #{from} · you named them"

  defp header_title(name) when name in [nil, ""], do: "Someone new"
  defp header_title(name), do: name

  defp scene_line(1), do: "In 1 scene"
  defp scene_line(n), do: "In #{n} scenes"

  defp empty_pressure(:compulsion), do: "Nothing drives them."
  defp empty_pressure(_), do: "Nothing gives."

  defp after_label(:compulsion), do: "and now"
  defp after_label(_), do: "and then"

  defp pressure_label(:compulsion), do: "if resisted"
  defp pressure_label(_), do: "if pushed"

  # A gate that will never move is the pencil (an editorial fact about the sheet);
  # one the story can still turn is the lamp; one with no gate at all is done.
  defp stance_colour(:closed), do: "var(--pencil)"
  defp stance_colour(:conditional), do: "var(--lamp)"
  defp stance_colour(_), do: "var(--ok)"

  defp stance_label(:closed, :compulsion), do: "Always"
  defp stance_label(:closed, _), do: "Never"
  defp stance_label(:conditional, :compulsion), do: "Until"
  defp stance_label(:conditional, _), do: "Not yet"
  defp stance_label(:open, :compulsion), do: "Freely"
  defp stance_label(_, _), do: "Open"

  defp category_label(:sexual), do: "sex"
  defp category_label(:graphic_violence), do: "graphic violence"
  defp category_label(cat), do: to_string(cat)

  defp group_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled group (##{entry.id})"
    end
  end

  defp group_hue(entry) do
    case Library.payload(entry) do
      %{hue: hue} -> Voice.colour(hue)
      _ -> Voice.neutral()
    end
  end

  defp joinable(all, joined) do
    held = MapSet.new(joined, & &1.id)
    Enum.reject(all, &MapSet.member?(held, &1.id))
  end

  # Each relationship with its index and its target's voice colour, resolved before
  # the template rather than inside it — the same person is the same hue here as in
  # the transcript. Someone who doesn't exist yet has no hue and gets the neutral one.
  defp rel_rows(relationships, hues) do
    for {%Relationship{target_id: id, target: name} = r, i} <- Enum.with_index(relationships) do
      colour =
        Map.get(hues, id) || Map.get(hues, String.downcase(to_string(name || ""))) ||
          Voice.neutral()

      {r, i, colour}
    end
  end

  # A relationship's target: a link to that character's sheet when it's an existing
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
    <.link :if={@id} navigate={~p"/authoring/character/#{@id}"} data-confirm={@confirm}>
      <%= @target %>
    </.link>
    <span :if={is_nil(@id)}><%= @target %></span>
    """
  end

  # The leave-confirmation message when there are unsaved edits, else nil (which
  # renders no data-confirm attribute, so a clean page never prompts).
  defp leave_confirm(true), do: "You have unsaved changes. Leave without saving?"
  defp leave_confirm(false), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
