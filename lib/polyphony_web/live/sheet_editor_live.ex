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

  alias Polyphony.{Campaigns, Characters, Groups, Library, Repo}
  alias Polyphony.Authoring.Knowledge
  alias Polyphony.Owner
  alias Polyphony.Authoring.{Audience, CharacterSheet, Stub, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.{Boundary, Fact, Relationship}
  alias Polyphony.Authoring.BoundaryGate
  alias PolyphonyCore.Content
  alias PolyphonyCore.Content.CampaignConfig
  alias Polyphony.ReadModels.Membership
  alias Polyphony.Permissions
  alias PolyphonyWeb.{AudiencePicker, Autosave, Generating, Guard, Screens, Voice}

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

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "character" &&
         Permissions.can_edit?(entry, socket.assigns.current_user) do
      # struct/2 fills any field the stored struct predates (e.g. world_bible_id).
      sheet = struct(CharacterSheet, Map.from_struct(Library.payload(entry)))
      owner = Owner.of(socket.assigns.current_user)
      campaign = Campaigns.of_character(owner, entry.id)
      worlds = load_worlds(socket.assigns.current_user)
      world_id = world_of(campaign, sheet)

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
         campaign: campaign,
         # The campaign's content ceiling (§A5 layer 2), so the editor can't be used to
         # open a boundary the campaign forbids — see `content_ceiling/1`.
         content_ceiling: content_ceiling(campaign),
         ensemble_context: ensemble_context(owner, campaign, entry.id),
         world_id: world_id,
         world_context: world_context_for(worlds, world_id),
         relationships: sheet.relationships || [],
         relations_context:
           relations_context(sheet.relationships || [], socket.assigns.current_user, entry.id),
         boundaries: sheet.boundaries || [],
         facts: sheet.facts || [],
         scene_count: scene_count(entry.id),
         groups:
           group_rows(Groups.for_character(Owner.of(socket.assigns.current_user), entry.id)),
         all_groups: group_rows(Groups.list(Owner.of(socket.assigns.current_user)))
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
          # §V8a: the ceiling is applied *here*, not only at scene assembly, so an author
          # never saves an open boundary that play would silently hold closed. Capping is
          # toward refusal — a compulsion the campaign forbids becomes a line against the
          # same topic, since the alternative is a ceiling that compels what it forbids.
          {status, boundary} =
            params |> Boundary.from_map() |> constrain(socket.assigns.content_ceiling)

          {:noreply,
           socket
           |> assign(boundaries: socket.assigns.boundaries ++ [boundary])
           |> touch()
           |> view_patch(panel: nil)
           |> constrained_flash(status, boundary)}
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

  # The overlay's three ways out — the ×, the scrim and Escape — all push this. They
  # carry no section, and shouldn't have to: there is only ever one drawer open.
  def handle_event("close_drawer", _params, socket),
    do: {:noreply, view_patch(socket, drawer: nil)}

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
      groups: group_rows(Groups.for_character(owner, socket.assigns.entry.id)),
      all_groups: group_rows(Groups.list(owner))
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

  # The cover, last and separately — the same order Quick Build writes in, and for the
  # same reason: a cover is written *from* everything else, so asking for it in the one
  # call that produces "everything else" would be asking it to describe fields that do
  # not exist yet.
  #
  # It is chained here rather than left for the author because the alternative is what
  # we had: "✦ Write every field" wrote every field except the one a stranger actually
  # reads. Only onto an empty cover, like the facts and the two suggestion passes —
  # a redraft of prose somebody has already approved is a second author, not a first.
  defp maybe_generate_cover(socket) do
    if Screens.SheetEditor.blank_cover?(socket.assigns.cover) do
      Generating.request(socket, "cover", "cover", %{
        subject: draft_sheet(socket),
        opts: gen_opts(socket)
      })
    else
      socket
    end
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
     |> maybe_suggest_boundaries()
     |> maybe_generate_cover()}
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
        # A suggestion is the likeliest way an over-the-ceiling boundary arrives, since
        # nothing told the model what the campaign permits.
        constrained =
          Enum.map(list, fn s ->
            s |> Boundary.from_map() |> constrain(socket.assigns.content_ceiling)
          end)

        boundaries = Enum.map(constrained, &elem(&1, 1))
        capped = Enum.count(constrained, &match?({:constrained, _}, &1))

        {:noreply,
         socket
         |> assign(boundaries: socket.assigns.boundaries ++ boundaries)
         |> touch()
         |> put_flash(
           :info,
           "Added #{length(boundaries)} suggested boundary(ies)#{capped_note(capped)}. Review and Save."
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
    for %{id: id, target: target} <- stubs,
        r = reciprocals[target],
        Screens.SheetEditor.present_string?(r) do
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
        pronouns: Screens.SheetEditor.blank_to_nil(socket.assigns.pronouns),
        role: Screens.SheetEditor.blank_to_nil(socket.assigns.role),
        cover: Screens.SheetEditor.blank_to_nil(socket.assigns.cover),
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
        pronouns: Screens.SheetEditor.blank_to_nil(socket.assigns.pronouns),
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
    named = for r <- socket.assigns.relations_context, into: MapSet.new(), do: down(r["name"])

    [
      world: socket.assigns.world_context,
      relations: socket.assigns.relations_context,
      # See `ensemble_context/3`. Quick Build has passed this since two blank slots
      # produced two of the same person; this screen makes the identical call with the
      # identical blank brief and was passing nothing.
      ensemble:
        Enum.reject(socket.assigns.ensemble_context, &MapSet.member?(named, down(&1["name"]))),
      # The live, possibly-edited role (falls back to the stub's inherited one).
      role: Screens.SheetEditor.blank_to_nil(socket.assigns.role) || socket.assigns.sheet.role,
      usage_kind: "authoring"
    ] ++ user_attribution(socket)
  end

  defp down(name), do: name |> to_string() |> String.trim() |> String.downcase()

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
      # Resolving an audience walks group membership, which is a read — so it is
      # answered here and the screen is handed the list.
      resolved_audience: resolved_audience(socket),
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

    assign(socket, knows: Knowledge.known_by(me, sources))
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

  # **The campaign's world, not a choice.** A character belongs to one campaign (§2.7)
  # and a campaign holds its own copy of a bible, so the character's setting is already
  # decided by the time this screen opens — a picker offering the other worlds in the
  # library could only ever be used to ground a character in a setting their campaign
  # doesn't play in, and (since attaching copies) most of the options were other
  # campaigns' working copies anyway.
  #
  # Read from the campaign first so it stays right: a campaign that swaps its world
  # would otherwise leave every character pointing at the old copy until each was opened
  # and re-picked. `world_bible_id` on the sheet is still written on save, so the stored
  # value converges on the campaign's, and a character with no campaign keeps whatever
  # it was given.
  @doc """
  The categories this character's campaign permits, or `:unbounded`.

  §A5 layer 2 is a property of the **campaign**, not of the person looking, so the floor is
  taken as attested here: capping an author's own sheet differently depending on whether
  they had attested would make the stored data depend on the viewer.

  A character in no campaign is `:unbounded` rather than the all-off default. The default
  config means *this campaign permits nothing*, which is the right answer for a campaign
  and exactly the wrong one for a character who does not have one — it would cap every
  categorized boundary on a standalone sheet.
  """
  @spec content_ceiling(map() | nil) :: [PolyphonyCore.Content.category()] | :unbounded
  def content_ceiling(nil), do: :unbounded

  def content_ceiling(campaign) do
    campaign
    |> Library.payload()
    |> CampaignConfig.from_payload()
    |> Content.register(attested: true)
  end

  # Cap a boundary against the ceiling, or leave it alone when there is none to cap
  # against. Returns `{:ok, b}` / `{:constrained, b}` the way `constrain_boundary/2` does,
  # so the caller counts the same shape either way.
  defp constrain(boundary, :unbounded), do: {:ok, boundary}
  defp constrain(boundary, register), do: BoundaryGate.constrain_boundary(boundary, register)

  # A silent cap would read as the form losing what was typed. Say what happened and where
  # to change it, since the fix is on the campaign screen rather than this one.
  defp constrained_flash(socket, :ok, _boundary), do: socket

  defp constrained_flash(socket, :constrained, boundary) do
    put_flash(
      socket,
      :info,
      "Saved as a line she holds: this campaign doesn't allow #{Content.label(boundary.category)}. " <>
        "Turn the category on in the campaign's content settings to open it."
    )
  end

  defp capped_note(0), do: ""

  defp capped_note(n),
    do: " (#{n} held closed — the campaign doesn't allow that content)"

  defp world_of(campaign, sheet) do
    from_campaign =
      case campaign && Library.payload(campaign) do
        %{bible_id: id} when not is_nil(id) -> to_string(id)
        _ -> nil
      end

    from_campaign || if(sheet.world_bible_id, do: to_string(sheet.world_bible_id), else: "")
  end

  defp ensemble_context(_owner, nil, _self_id), do: []

  defp ensemble_context(_owner, campaign, self_id) do
    ids = (Map.get(Library.payload(campaign) || %{}, :character_ids) || []) -- [self_id]

    for id <- ids, entry = Library.get(id), entry != nil, sheet = Library.payload(entry) do
      %{
        "name" => sheet.name,
        "premise" => sheet.premise,
        "voice" => sheet.voice,
        "temperament" => sheet.temperament
      }
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

  def render(assigns) do
    ~H"""
    <Screens.SheetEditor.screen
      all_groups={@all_groups}
      blocks={@blocks}
      boundaries={@boundaries}
      brief_open={@brief_open}
      campaign={@campaign && %{id: @campaign.id, name: campaign_name(@campaign)}}
      char_hues={@char_hues}
      char_links={@char_links}
      char_names={@char_names}
      cover={@cover}
      current_user={@current_user}
      dirty={@dirty}
      drawer={@drawer}
      entry={@entry}
      facts={@facts}
      generating={@generating}
      groups={@groups}
      knows={@knows}
      name={@name}
      panel={@panel}
      picker_groups={@picker_groups}
      picker_labels={@picker_labels}
      picker_people={@picker_people}
      pronouns={@pronouns}
      relationships={@relationships}
      resolved_audience={@resolved_audience}
      audience_at={@audience_at}
      role={@role}
      saved={@saved}
      scene_count={@scene_count}
      sheet={@sheet}
      tier={@tier}
      world_context={@world_context}
    />
    """
  end

  # The one field the editor needs off the campaign entry, resolved here so the screen
  # can stay a function of assigns.
  defp campaign_name(campaign) do
    case String.trim(to_string(Map.get(Library.payload(campaign) || %{}, :name) || "")) do
      "" -> nil
      name -> name
    end
  end

  # `%{id, name, hue}` rather than library entries — the screen renders from assigns and
  # unwrapping a payload per row is the read it may not do.
  defp group_rows(entries),
    do: Enum.map(entries, &%{id: &1.id, name: group_name(&1), hue: group_hue(&1)})

  # Who can already see the fact whose picker is open, if one is.
  defp resolved_audience(%{assigns: %{audience_at: i, facts: facts, entry: entry}})
       when is_integer(i) do
    case Enum.at(facts, i) do
      nil -> []
      fact -> Knowledge.resolve(fact.audience, owner: entry.id)
    end
  end

  defp resolved_audience(_socket), do: []
end
