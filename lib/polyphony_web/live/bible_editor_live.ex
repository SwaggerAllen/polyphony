defmodule PolyphonyWeb.BibleEditorLive do
  @moduledoc """
  The world bible, ported from `ux/polyphony-world.html`.

  Same long-form shape as the character sheet — one scroll, a sticky `Kit.jump`, no
  accordions — because it is the same problem and the design uses one navigation
  primitive for both, so it still works when either grows.

  ## Two kinds of field, deliberately

  **Prose** (setting, tone) is edited as paragraph blocks with Rewrite and Expand.
  **Lists** (rules, what's already true) are items with their own menu: a secret
  toggle, move up, delete. They are not the same control and the design doesn't
  pretend they are — a rule is one statement you reorder, a paragraph is prose you
  rewrite.

  ## The cover, and what it must not say

  The cover is the only part strangers see before they take the world, and it is
  written from everything below it *including the secrets* (`Polyphony.Authoring.Cover`,
  §2.12). This screen shows what was checked, because a claim that a blurb is
  spoiler-free is worth nothing unless it says what it was checked against.

  ## Secrets are structural here, not decorative

  Marking a rule or a canon entry secret keeps it out of every character's context
  (`WorldBible.public/1`) — not out of a rendering, out of the *prompt*. The preview
  below the editor shows exactly that filter, so what an author previews is what a
  character actually gets rather than a second implementation that can drift.

  **Preview is read-only**, per §3.2: editing a bible while looking at a filtered
  version of it is how someone deletes something they couldn't see.

  ## A library world is a template

  Attaching one to a campaign copies it (§2.5b), so the editor says which side of that
  it is on: a template says how many campaigns were started from it and that edits
  reach none of them; a campaign's own copy says it has a history, and offers the one
  deliberate route back — *save a copy to your library*, a snapshot rather than a link.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.{Campaigns, Characters, Groups, Library, Owner}
  alias Polyphony.Permissions
  alias Polyphony.Authoring.{Audience, WorldBible}
  alias Polyphony.Authoring.WorldBible.Entry
  alias PolyphonyWeb.{AudiencePicker, Autosave, Generating, Guard, Kit, Layouts}

  # Prose, edited as paragraph blocks.
  @prose_specs [{"setting", "Setting"}, {"tone", "Tone"}]
  @prose_fields Enum.map(@prose_specs, &elem(&1, 0))

  # Lists of statements, edited as items. Both are `WorldBible.Entry` lists, and both
  # carry the same secret control — that sameness is the design's point (§04).
  @list_specs [
    {"rules", "Rules", "Add a rule…"},
    {"starting_canon", "What's already true", "Add something that's true…"}
  ]
  @list_fields Enum.map(@list_specs, &elem(&1, 0))

  @stops [
    {"cover", "Cover"},
    {"name", "Name"},
    {"setting", "Setting"},
    {"tone", "Tone"},
    {"rules", "Rules"},
    {"starting_canon", "What's true"},
    {"sharing", "Sharing"}
  ]

  defp prose_specs, do: @prose_specs
  defp list_specs, do: @list_specs
  defp stops, do: @stops

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == "world_bible" &&
         Permissions.can_edit?(entry, socket.assigns.current_user) do
      bible = struct(WorldBible, Map.from_struct(Library.payload(entry)))

      {:ok,
       socket
       |> assign(
         page_title: bible.name || "World",
         entry: entry,
         campaign: Campaigns.of_world(Owner.of(socket.assigns.current_user), entry.id),
         bible: bible,
         name: bible.name || "",
         name_error: nil,
         name_clash: nil,
         cover: bible.cover,
         blocks: blocks_from_bible(bible),
         items: items_from_bible(bible),
         gen_subject: entry.id,
         generating: MapSet.new(),
         saved: false,
         dirty: false,
         autosave_ref: nil,
         drawer: nil,
         panel: nil,
         preview: false,
         brief_open: false,
         # {field, index} of the item whose audience is open, or nil.
         audience_at: nil
       )
       |> Generating.restore()
       |> assign_lineage()
       |> assign_audience_sources()}
    else
      # Missing, moderated, or somebody else's — `Guard` decides which of those it is
      # safe to say. Editing what you don't own was never an affordance here; it was
      # reachable because the mount asked whether the entry existed and stopped there.
      Guard.refuse(socket, entry, "World bible", socket.assigns.current_user)
    end
  end

  @doc false
  # Which panel, drawer, picker or preview is open lives in the **URL**, not in the
  # socket. The reason is the same one that moved Quick Build out of a task: a LiveView
  # process ends when its socket does, and everything it was holding ends with it. A
  # phone that backgrounds a tab for a minute comes back to a fresh mount, and anything
  # the assigns alone knew is gone.
  #
  # Two things fall out of it for free, and both are worth more than the reconnect: the
  # back button closes what's open — which on a phone is the gesture people already
  # reach for — and a URL now describes a place rather than a page.
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       panel: present(params["panel"]),
       drawer: present(params["drawer"]),
       preview: params["preview"] == "1",
       audience_at: decode_audience(params["audience"])
     )}
  end

  # `{field, index}`, over the wire as `rules:2`. Default-deny on the field name: an
  # unknown one is no picker rather than a crash, which is also why nothing here ever
  # builds an atom out of a query string.
  defp decode_audience(nil), do: nil

  defp decode_audience(value) when is_binary(value) do
    with [field, index] <- String.split(value, ":", parts: 2),
         true <- field in @list_fields,
         {i, ""} <- Integer.parse(index) do
      {field, i}
    else
      _ -> nil
    end
  end

  defp encode_audience({field, index}), do: "#{field}:#{index}"
  defp encode_audience(_), do: nil

  # Patch to the same screen with the view state changed. A push rather than a replace:
  # closing a panel with Back is the behaviour a phone user expects, and history is
  # where that expectation is met.
  defp view_patch(socket, changes) do
    params =
      %{
        "panel" => socket.assigns.panel,
        "drawer" => socket.assigns.drawer,
        "preview" => socket.assigns.preview && "1",
        "audience" => encode_audience(socket.assigns.audience_at)
      }
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> v in [nil, false, ""] end)

    push_patch(socket, to: ~p"/authoring/bible/#{socket.assigns.entry.id}?#{params}")
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value

  # ── Editing ───────────────────────────────────────────────────────────────────

  def handle_event("sync", params, socket) do
    {:noreply, socket |> assign_form(params) |> touch()}
  end

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      socket = socket |> assign_form(params) |> Autosave.cancel()

      case persist(socket) do
        {:ok, socket} ->
          {:noreply, socket}

        {:clash, socket} ->
          # Also flashed, not only marked at the field. Save sits at the foot of a
          # sheet several viewports tall and Name is at its head, so the refusal
          # rendered somewhere the author wasn't looking — pressing Save read as
          # nothing happening at all, which is how a working guard becomes "saving is
          # broken".
          {:noreply,
           put_flash(
             socket,
             :error,
             "Not saved under that name — you already have a world called " <>
               String.trim(socket.assigns.name) <> "."
           )}
      end
    end)
  end

  def handle_event("add_block", %{"field" => f}, socket) when f in @prose_fields do
    {:noreply, update_blocks(socket, f, &(&1 ++ [""]))}
  end

  def handle_event("remove_block", %{"field" => f, "index" => i}, socket)
      when f in @prose_fields do
    {:noreply, update_blocks(socket, f, &drop_block(&1, String.to_integer(i)))}
  end

  # ── List items (§04) ────────────────────────────────────────────────────────

  def handle_event("add_item", %{"field" => f, "statement" => statement}, socket)
      when f in @list_fields do
    safe(socket, fn ->
      case String.trim(statement) do
        "" ->
          {:noreply, put_flash(socket, :error, "Write it first.")}

        text ->
          {:noreply,
           socket
           |> update_items(f, &(&1 ++ [%Entry{statement: text}]))
           |> view_patch(panel: nil)}
      end
    end)
  end

  def handle_event("remove_item", %{"field" => f, "index" => i}, socket)
      when f in @list_fields do
    {:noreply, update_items(socket, f, &List.delete_at(&1, String.to_integer(i)))}
  end

  # The same control in three places (§04) — identical here, on a character's facts,
  # and wherever locations land. What it *means* is structural: see the moduledoc.
  def handle_event("toggle_secret", %{"field" => f, "index" => i}, socket)
      when f in @list_fields do
    idx = String.to_integer(i)

    {:noreply,
     update_items(socket, f, fn items ->
       List.update_at(items, idx, &%Entry{&1 | concealed: not &1.concealed})
     end)}
  end

  def handle_event("move_item", %{"field" => f, "index" => i, "by" => by}, socket)
      when f in @list_fields do
    idx = String.to_integer(i)
    delta = String.to_integer(by)

    {:noreply, update_items(socket, f, &move_block(&1, idx, delta))}
  end

  # ── Generation ──────────────────────────────────────────────────────────────

  def handle_event("generate_all", %{"brief" => brief}, socket) do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request("all", "autofill.all", %{
         kind: :world_bible,
         brief: brief,
         current: current,
         opts: opts
       })}
    end)
  end

  def handle_event("generate_field", %{"field" => f}, socket) when f in @prose_fields do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request(f, "autofill.field", %{
         kind: :world_bible,
         field: f,
         current: current,
         opts: opts
       })}
    end)
  end

  def handle_event("expand_field", %{"field" => f}, socket) when f in @prose_fields do
    safe(socket, fn ->
      opts = paragraph_opts(socket, f, nil)

      {:noreply,
       socket
       |> Generating.request("#{f}:expand", "autofill.paragraph", %{
         kind: :world_bible,
         field: f,
         opts: opts
       })}
    end)
  end

  def handle_event("generate_block", %{"field" => f, "index" => i}, socket)
      when f in @prose_fields do
    idx = String.to_integer(i)

    safe(socket, fn ->
      opts = paragraph_opts(socket, f, idx)

      {:noreply,
       socket
       |> Generating.request("#{f}:#{idx}", "autofill.paragraph", %{
         kind: :world_bible,
         field: f,
         opts: opts
       })}
    end)
  end

  # ✦ Suggest on a list **appends** what's new rather than replacing the list. A list
  # is authored — reordered, marked secret, argued over — and regenerating it whole
  # would throw that away to make room for a suggestion.
  def handle_event("suggest_items", %{"field" => f}, socket) when f in @list_fields do
    safe(socket, fn ->
      current = current_values(socket)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request(f, "autofill.field", %{
         kind: :world_bible,
         field: f,
         current: current,
         opts: opts
       })}
    end)
  end

  # ── Cover (§2.12) ───────────────────────────────────────────────────────────

  def handle_event("generate_cover", _params, socket) do
    safe(socket, fn ->
      bible = draft_bible(socket.assigns)
      opts = gen_opts(socket)

      {:noreply,
       socket
       |> Generating.request("cover", "cover", %{subject: bible, opts: opts})}
    end)
  end

  # ── Sharing ─────────────────────────────────────────────────────────────────

  def handle_event("set_visibility", %{"visibility" => v}, socket)
      when v in ["private", "unlisted", "public"] do
    safe(socket, fn ->
      {:ok, entry} = Library.set_visibility(socket.assigns.entry.id, v)
      {:noreply, assign(socket, entry: entry)}
    end)
  end

  def handle_event("rotate_link", _params, socket) do
    safe(socket, fn ->
      {:ok, entry} = Library.rotate_share_token(socket.assigns.entry.id)

      {:noreply,
       socket
       |> assign(entry: entry)
       |> put_flash(:info, "New link. The old one stopped working.")}
    end)
  end

  # ── Template / copy (§2.5b) ─────────────────────────────────────────────────

  def handle_event("save_to_library", _params, socket) do
    safe(socket, fn ->
      copy = Library.copy(socket.assigns.entry, socket.assigns.current_user)

      {:noreply,
       socket
       |> assign_lineage()
       |> put_flash(:info, "Saved a copy to your library — a snapshot of it as it is now.")
       |> push_navigate(to: ~p"/authoring/bible/#{copy.id}")}
    end)
  end

  # ── Audience (§3.3) ─────────────────────────────────────────────────────────

  # Only reachable on a secret: nothing appears until an item is marked, and the
  # audience line is then part of the item so the count is readable without opening
  # anything (`ux/polyphony-audience-picker.html` §01).
  def handle_event("open_audience", %{"field" => f, "index" => i}, socket)
      when f in @list_fields do
    {:noreply, view_patch(socket, audience: "#{f}:#{i}", panel: nil)}
  end

  def handle_event("close_audience", _params, socket),
    do: {:noreply, view_patch(socket, audience: nil)}

  def handle_event("toggle_audience", %{"kind" => kind, "id" => id}, socket) do
    case socket.assigns.audience_at do
      {field, index} ->
        {:noreply,
         update_items(socket, field, fn items ->
           List.update_at(items, index, fn item ->
             %Entry{item | audience: toggle(item.audience, kind, id)}
           end)
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Chrome ──────────────────────────────────────────────────────────────────

  def handle_event("drawer", %{"section" => section}, socket) do
    {:noreply,
     view_patch(socket, drawer: if(socket.assigns.drawer == section, do: nil, else: section))}
  end

  # The overlay's three ways out — the ×, the scrim and Escape — all push this. They
  # carry no section, and shouldn't have to: there is only ever one drawer open.
  def handle_event("close_drawer", _params, socket),
    do: {:noreply, view_patch(socket, drawer: nil)}

  def handle_event("panel", %{"panel" => panel}, socket) do
    {:noreply,
     view_patch(socket,
       panel: if(panel == "" or socket.assigns.panel == panel, do: nil, else: panel)
     )}
  end

  def handle_event("toggle_brief", _params, socket),
    do: {:noreply, assign(socket, brief_open: not socket.assigns.brief_open)}

  def handle_event("preview", %{"as" => as}, socket) do
    {:noreply, view_patch(socket, preview: as != "" && "1")}
  end

  # ── Async results ─────────────────────────────────────────────────────────────

  # ── Results ───────────────────────────────────────────────────────────────────
  #
  # Same bodies as the `handle_async` clauses they replace: the screen is still the only
  # thing that decides what a result means, which is the part worth keeping in one place
  # (Suggest appends, Generate-all fills only blanks, a leaked cover is refused). What
  # changed is where the work ran — see `Polyphony.Generations`. A result that arrived
  # while the page was closed comes back through here on the next mount, so there is one
  # code path either way.

  def handle_info({:generation, "all", {:ok, values}}, socket) do
    blocks =
      Enum.reduce(@prose_fields, socket.assigns.blocks, fn f, acc ->
        if values[f] in [nil, ""], do: acc, else: Map.put(acc, f, to_blocks(values[f]))
      end)

    # Generation only *fills* a list that's empty. An authored list has an order and
    # secret flags on it that a wholesale replacement would silently discard.
    items =
      Enum.reduce(@list_fields, socket.assigns.items, fn f, acc ->
        if values[f] in [nil, ""] or acc[f] != [],
          do: acc,
          else: Map.put(acc, f, entries_from_text(values[f]))
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]

    {:noreply,
     socket
     |> assign(name: name, blocks: blocks, items: items)
     |> mark("all", false)
     |> touch()
     |> maybe_generate_cover()}
  end

  def handle_info({:generation, "cover", {:ok, cover}}, socket) do
    {:noreply, socket |> assign(cover: cover) |> mark("cover", false) |> touch()}
  end

  # The leak refusal gets its own message: what happened isn't a broken feature, it's
  # a cover that kept quoting a secret and was thrown away on purpose.
  def handle_info({:generation, "cover", {:error, :leaked}}, socket) do
    {:noreply,
     socket
     |> mark("cover", false)
     |> put_flash(
       :error,
       "The cover kept giving a secret away, so it wasn't kept. Try again, or write it yourself."
     )}
  end

  # The quiet write. Nothing here is a decision the author hasn't already made by
  # typing, which is the rule for anything that fires on a timer.
  def handle_info({:generation, f, {:ok, value}}, socket) when f in @prose_fields do
    {:noreply, socket |> put_blocks(f, to_blocks(value)) |> mark(f, false) |> touch()}
  end

  # ✦ Suggest on a list **appends** what's new rather than replacing it. A list is
  # authored — reordered, marked secret, argued over — and regenerating it whole would
  # throw that away to make room for a suggestion.
  def handle_info({:generation, f, {:ok, value}}, socket) when f in @list_fields do
    socket = mark(socket, f, false)
    held = MapSet.new(socket.assigns.items[f], &normalize(&1.statement))
    fresh = Enum.reject(entries_from_text(value), &MapSet.member?(held, normalize(&1.statement)))

    case fresh do
      [] ->
        {:noreply, put_flash(socket, :info, "Nothing new suggested.")}

      new ->
        {:noreply,
         socket
         |> update_items(f, &(&1 ++ new))
         |> put_flash(:info, "Added #{length(new)}. Review and Save.")}
    end
  end

  # A paragraph: either appended to a field (`"tone:expand"`) or replacing one block of
  # it (`"tone:2"`). One operation, two keys, because they differ only in where the
  # answer goes.
  def handle_info({:generation, key, {:ok, para}}, socket) do
    case String.split(key, ":", parts: 2) do
      [f, "expand"] when f in @prose_fields ->
        {:noreply,
         socket
         |> put_blocks(f, append_paragraph(socket.assigns.blocks[f], para))
         |> mark(key, false)
         |> touch()}

      [f, index] when f in @prose_fields ->
        idx = String.to_integer(index)
        blocks = List.replace_at(socket.assigns.blocks[f], idx, para)
        {:noreply, socket |> put_blocks(f, blocks) |> mark(key, false) |> touch()}

      _ ->
        {:noreply, mark(socket, key, false)}
    end
  end

  def handle_info(:autosave, socket) do
    {:noreply, elem(persist(socket), 1)}
  end

  def handle_info({:generation, key, result}, socket),
    do: {:noreply, gen_failed(socket, key, result)}

  # The tab going away is the case this whole mechanism exists for, and the pending
  # timer dies with the process.
  def terminate(_reason, socket), do: Autosave.flush(socket, &persist/1)

  # Write the bible as it currently stands, and answer whether the *name* went with it.
  #
  # The name is the one field with a gate on it (§03: two worlds called Saltmarch is a
  # mistake heading somewhere confusing, and only the author can say which they meant),
  # so a clash holds the name back and lets everything else through. Refusing the whole
  # sheet over it would mean an autosave discarding the prose it exists to protect —
  # and, on an explicit save, throwing away an afternoon's writing to enforce a label.
  defp persist(socket) do
    %{name: name, blocks: blocks, items: items, entry: entry} = socket.assigns

    clash =
      Library.name_clash(Owner.of(socket.assigns.current_user), "world_bible", name,
        except: entry.id
      )

    bible = %WorldBible{
      socket.assigns.bible
      | name: if(clash, do: socket.assigns.bible.name, else: name),
        cover: blank_to_nil(socket.assigns.cover),
        setting: join_blocks(blocks["setting"]),
        tone: join_blocks(blocks["tone"]),
        rules: items["rules"],
        starting_canon: items["starting_canon"]
    }

    {:ok, entry} = Library.update_payload(entry.id, bible)

    socket =
      socket
      |> assign(
        entry: entry,
        bible: bible,
        name_error: clash && "You already have a world called #{String.trim(name)}.",
        name_clash: clash,
        blocks: blocks_from_bible(bible),
        items: items_from_bible(bible)
      )
      |> Autosave.saved()

    # The name field keeps what was typed on a clash — retyping it is the author's job,
    # and silently reverting the field would hide the very thing being complained about.
    if clash, do: {:clash, socket}, else: {:ok, assign(socket, name: bible.name)}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp assign_form(socket, params) do
    assign(socket,
      name: params["name"] || socket.assigns.name,
      cover: params["cover"] || socket.assigns.cover,
      blocks:
        Map.new(@prose_fields, fn f ->
          {f, param_blocks(params["b_#{f}"], socket.assigns.blocks[f])}
        end)
    )
  end

  # Where this bible sits in the template relationship (§2.5b): how many copies were
  # taken from it, and whether it is itself one.
  defp assign_lineage(socket) do
    entry = socket.assigns.entry

    assign(socket,
      copy_count: Library.copy_count(entry.id),
      copied_from: entry.derived_from_id && Library.get(entry.derived_from_id)
    )
  end

  defp update_blocks(socket, field, fun),
    do: socket |> put_blocks(field, fun.(socket.assigns.blocks[field])) |> touch()

  defp put_blocks(socket, field, blocks),
    do: assign(socket, :blocks, Map.put(socket.assigns.blocks, field, ensure_one(blocks)))

  defp toggle(audience, "group", id), do: Audience.toggle_group(Audience.from(audience), id)

  defp toggle(audience, _character, id),
    do: Audience.toggle_character(Audience.from(audience), id)

  # The campaign cast and groups the picker offers. A world is authored against an
  # owner's library rather than one campaign, so this is everything they've written —
  # which is also what the design's "41 characters" case looks like.
  defp assign_audience_sources(socket) do
    owner = Owner.of(socket.assigns.current_user)
    characters = Characters.list(owner)
    groups = Groups.list(owner)

    assign(socket,
      picker_groups:
        for g <- groups do
          {to_string(g.id), entry_name(g, "Untitled group"), group_note(g)}
        end,
      picker_people:
        for c <- characters do
          sheet = Library.payload(c)

          {to_string(c.id), entry_name(c, "Unnamed"), Characters.tier_of(c),
           AudiencePicker.colour(sheet)}
        end,
      picker_labels: Map.new(groups ++ characters, &{to_string(&1.id), entry_name(&1, "Unnamed")})
    )
  end

  defp group_note(entry) do
    case length(Groups.member_ids(entry.id)) do
      0 -> {:empty, 0}
      n -> {:count, n}
    end
  end

  defp entry_name(entry, fallback) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> fallback
    end
  end

  defp update_items(socket, field, fun) do
    socket
    |> assign(:items, Map.put(socket.assigns.items, field, fun.(socket.assigns.items[field])))
    |> touch()
  end

  defp blocks_from_bible(bible),
    do: Map.new(@prose_fields, fn f -> {f, to_blocks(Map.get(bible, field_atom(f)))} end)

  defp items_from_bible(bible),
    do: Map.new(@list_fields, fn f -> {f, WorldBible.entries(Map.get(bible, field_atom(f)))} end)

  defp field_atom(f), do: String.to_existing_atom(f)

  defp entries_from_text(value),
    do: value |> to_line_blocks() |> block_list() |> Enum.map(&%Entry{statement: &1})

  defp normalize(s), do: s |> to_string() |> String.trim() |> String.downcase()

  # The bible as it stands in the form, unsaved edits included — the cover has to be
  # written from what the author is looking at, secrets and all.
  # Takes assigns rather than the socket, because the template needs it too — the
  # preview has to show unsaved edits or it would be previewing the last save.
  # The cover, chained rather than folded into `autofill.all`. A cover is written *from*
  # everything else — the setting, the tone, the rules and the canon, secrets included,
  # under instruction to give none of them away (§2.12) — so asking for it in the call
  # that produces those fields is asking it to describe fields that do not exist yet.
  # It is written last for the same reason in Quick Build, and on the character sheet.
  #
  # Only onto an empty cover, like the lists above: a redraft of prose somebody has
  # already read and kept is a second author, not a first draft.
  defp maybe_generate_cover(socket) do
    if socket.assigns.cover in [nil, ""] do
      Generating.request(socket, "cover", "cover", %{
        subject: draft_bible(socket.assigns),
        opts: gen_opts(socket)
      })
    else
      socket
    end
  end

  defp draft_bible(%{bible: bible} = assigns) do
    %WorldBible{
      bible
      | name: assigns.name,
        cover: blank_to_nil(assigns.cover),
        setting: join_blocks(assigns.blocks["setting"]),
        tone: join_blocks(assigns.blocks["tone"]),
        rules: assigns.items["rules"],
        starting_canon: assigns.items["starting_canon"]
    }
  end

  defp current_values(socket) do
    prose = Map.new(@prose_fields, fn f -> {f, join_blocks(socket.assigns.blocks[f])} end)

    lists =
      Map.new(@list_fields, fn f ->
        {f, socket.assigns.items[f] |> Enum.map(& &1.statement) |> Enum.join("\n")}
      end)

    prose |> Map.merge(lists) |> Map.put("name", socket.assigns.name)
  end

  defp paragraph_opts(socket, field, index) do
    [blocks: socket.assigns.blocks[field], index: index, current: current_values(socket)] ++
      gen_opts(socket)
  end

  defp gen_opts(socket) do
    [usage_kind: "authoring"] ++
      case socket.assigns.current_user do
        %{id: id} -> [user_id: id]
        _ -> []
      end
  end

  defp touch(socket), do: Autosave.touch(socket)

  defp leave_confirm(true), do: "You have unsaved changes. Leave without saving?"
  defp leave_confirm(false), do: nil

  defp mark(socket, key, on?), do: Generating.mark(socket, key, on?)

  defp gen_failed(socket, key, result) do
    Logger.warning("[authoring] world generation failed (#{key}): #{inspect(result)}")

    socket
    |> mark(key, false)
    |> put_flash(:error, "Generation failed: #{inspect(reason(result))}")
  end

  defp reason({:ok, {:error, r}}), do: r
  defp reason({:exit, r}), do: r
  defp reason(other), do: other

  defp blank_to_nil(v) do
    case String.trim(to_string(v || "")) do
      "" -> nil
      s -> s
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <%!-- **`height`, not `min-height`.** A `min-h-[100dvh]` column grows with its
          content, so `flex-1 min-h-0 overflow-y-auto` inside it never has a height to
          be a fraction *of* — nothing scrolls, the page runs to whatever length the
          sheet is, and the `shrink-0` bar meant to hold the bottom of the viewport
          lands at the bottom of a document several screens tall. Play has always
          pinned its say-bar this way; these three didn't. --%>
    <Kit.frame class="flex flex-col min-h-0" style="height:100dvh">
      <Kit.header
        title={world_title(@name)}
        subtitle={lineage_line(assigns)}
        back={back_to(@campaign)}
        back_label={back_label(@campaign)}
        back_confirm={leave_confirm(@dirty)}
      >
        <:actions>
          <form id="preview-form" phx-change="preview">
            <Kit.viewas_select
              id="preview-select"
              label="Preview as"
              name="as"
              colour={if @preview, do: "var(--secret)", else: "var(--bc)"}
            >
              <option value="" selected={not @preview}>Omniscient</option>
              <%!-- Short here, spelled out in the banner: the control is a chip and a
                    long option would stretch it across the header. --%>
              <option value="stranger" selected={@preview}>A stranger</option>
            </Kit.viewas_select>
          </form>
          <Kit.pill><%= String.capitalize(@entry.visibility) %></Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- **Preview is read-only** (§3.2). Editing a bible while looking at a
            filtered version of it is how someone deletes something they couldn't
            see, so preview replaces the editor rather than sitting beside it. --%>
      <.preview :if={@preview} bible={draft_bible(assigns)} />

      <div :if={not @preview} class="flex flex-col flex-1 min-h-0">
        <Kit.jump class="shrink-0">
          <:stop :for={{id, label} <- stops()}>
            <a href={"##{id}"}><%= label %></a>
          </:stop>
        </Kit.jump>

        <div class="flex-1 min-h-0 overflow-y-auto">
          <%!-- One brief writes everything, and the field-by-field path stays visible
                underneath so it never reads as the only way in (§02). Like the
                campaign's Quick Build it folds away once there's a world here — it
                would be dead weight from this world's second day. --%>
          <Kit.sheet
            :if={@brief_open or empty_world?(assigns)}
            class="m-4"
            style={empty_world?(assigns) && "border-color:var(--lamp)"}
          >
            <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
              <span class="ttl text-[15px] font-semibold">Describe it in a line</span>
              <button
                :if={not empty_world?(assigns)}
                type="button"
                class="dim text-[17px] leading-none"
                phx-click="toggle_brief"
                aria-label="Close"
              >
                ×
              </button>
            </Kit.row>
            <div class="px-4 py-3">
              <form id="bible-generate-all" phx-submit="generate_all">
                <label for="brief" class="sr-only">Describe the world</label>
                <textarea
                  id="brief"
                  name="brief"
                  rows="2"
                  placeholder="A port town that runs on tides and debts…"
                  class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2"
                ></textarea>
                <Kit.btn kind={:primary} type="submit" disabled={busy?(@generating, "all")}>
                  <%= if busy?(@generating, "all"), do: "✦ Writing…", else: "✦ Write the whole bible" %>
                </Kit.btn>
              </form>
              <p class="text-[11px] leading-relaxed dim mt-2">
                Builds on anything already written rather than replacing it, and leaves an
                authored list alone.
              </p>
            </div>
          </Kit.sheet>

          <div :if={not @brief_open and not empty_world?(assigns)} class="px-4 pt-4">
            <Kit.btn size={:sm} type="button" phx-click="toggle_brief">✦ Write it from a line</Kit.btn>
          </div>

          <form id="bible-form" phx-submit="save" phx-change="sync">
            <Kit.sheet class="m-4">
              <%!-- ── Cover ─────────────────────────────────────────────────── --%>
              <div class="row px-4 py-3" id="cover">
                <div class="flex items-center justify-between gap-2 mb-2">
                  <span class="flex items-center gap-1.5">
                    <span class="lbl dim">Cover</span>
                    <Kit.info label="the cover" phx-click="drawer" phx-value-section="cover" />
                  </span>
                  <Kit.btn
                    kind={if(@cover in [nil, ""], do: :primary, else: :ghost)}
                    size={:sm}
                    type="button"
                    phx-click="generate_cover"
                    disabled={busy?(@generating, "cover")}
                  >
                    <%= cover_action(@cover, busy?(@generating, "cover")) %>
                  </Kit.btn>
                </div>

                <label for="cover-text" class="sr-only">Cover</label>
                <%!-- The slowest ✦ here, and now the tail of an even longer chained one,
                      so it draws where the words will land rather than leaving an empty
                      box that reads as nothing having happened. --%>
                <Kit.skel_lines
                  :if={busy?(@generating, "cover") and @cover in [nil, ""]}
                  lines={["100%", "95%", "48%"]}
                  label="Writing the cover"
                />
                <textarea
                  :if={not (busy?(@generating, "cover") and @cover in [nil, ""])}
                  id="cover-text"
                  name="cover"
                  rows="3"
                  phx-debounce="600"
                  class="field px-3 py-2.5 text-[13px] leading-relaxed w-full"
                  placeholder="Nothing here yet. This is the only part strangers see before they take your world."
                ><%= @cover %></textarea>

                <%!-- What the check was against, not just that it happened: "checked"
                      is worth nothing unless it says what it was checked against. --%>
                <div
                  :if={@cover not in [nil, ""] and secret_count(assigns) > 0}
                  class="flex items-center gap-2 mt-2.5 pt-2.5"
                  style="border-top:1px solid var(--rule)"
                >
                  <Kit.dot colour="var(--secret)" />
                  <span class="text-[11px] leading-relaxed dim">
                    <%= checked_line(secret_count(assigns)) %>
                  </span>
                </div>
                <p :if={@cover in [nil, ""]} class="text-[11px] leading-relaxed dim mt-1.5">
                  It'll be written from everything below — secrets included — with instructions
                  to give none of them away.
                </p>
              </div>

              <%!-- ── Name ──────────────────────────────────────────────────── --%>
              <div class="row px-4 py-3" id="name">
                <label for="bible-name" class="lbl dim">Name</label>
                <input
                  id="bible-name"
                  type="text"
                  name="name"
                  value={@name}
                  phx-debounce="600"
                  placeholder="Saltmarch"
                  class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
                  style={@name_error && "border-color:var(--pencil)"}
                />
                <div :if={@name_error} class="flex items-start gap-1.5 mt-1.5">
                  <Kit.dot colour="var(--pencil)" class="mt-1.5 shrink-0" />
                  <span class="text-[12px] leading-relaxed" style="color:var(--pencil)">
                    <%= @name_error %> Pick something else, or
                    <%!-- A real link, because the other world is usually one nobody
                          made on purpose — an interrupted Quick Build's leftover — and
                          "open that one" was advice with nowhere to click. --%>
                    <.link
                      :if={@name_clash}
                      navigate={~p"/authoring/bible/#{@name_clash.id}"}
                      class="underline"
                    >
                      open that one</.link><span :if={!@name_clash}>open that one</span>.
                  </span>
                </div>
              </div>

              <%!-- ── Prose ─────────────────────────────────────────────────── --%>
              <.block_field
                :for={{f, label} <- prose_specs()}
                id={f}
                field={f}
                label={label}
                blocks={@blocks[f]}
                generating={@generating}
              />

              <%!-- ── Lists ─────────────────────────────────────────────────── --%>
              <.item_list
                :for={{f, label, add} <- list_specs()}
                field={f}
                label={label}
                add_label={add}
                placeholder={panel_placeholder(f)}
                panel={@panel}
                items={@items[f]}
                generating={@generating}
                labels={@picker_labels}
                last={f == "starting_canon"}
              />
            </Kit.sheet>

          </form>

          <Kit.info_drawer :if={@drawer == "cover"} on_close="close_drawer" title="About the cover">
            <:intro>
              The existing fields are written for the Director — setting and tone are
              instructions to a model. Someone deciding whether to use this world wants
              different prose entirely, so the cover is its own field.
            </:intro>
            <:part colour="var(--secret)" name="It's written from the secrets">
              That's what stops it reading like a stranger wrote it. A draft that quotes one
              is thrown away rather than shown to you.
            </:part>
            <:part colour="var(--bcm)" name="You can take a world without reading it">
              Save it off the cover and find out what's in it while you play. For a writer
              who wants to be surprised by their own campaign, that's the point.
            </:part>
          </Kit.info_drawer>

          <Kit.info_drawer :if={@drawer == "secrets"} on_close="close_drawer" title="About secrets">
            <:intro>
              Anything here can be marked secret — a rule, something that's already true, a
              character's fact. It's one control in all three places.
            </:intro>
            <:part colour="var(--secret)" name="It stays out of the story, not just the page">
              A secret is absent from every character's context. They aren't told to ignore
              it; it isn't there. That's what makes it hold.
            </:part>
            <:part colour="var(--bc)" name="The Director still knows">
              Knowing a secret is how it aims a scene at one. The asymmetry is the feature.
            </:part>
            <:part colour="var(--bcm)" name="Who else knows comes later">
              For now a secret is known by nobody. Naming the people who start out in on it
              is the audience picker, which isn't built yet.
            </:part>
          </Kit.info_drawer>

          <%!-- Outside the form, like every other panel: it isn't part of the sheet's
                own submission, and a form inside a form isn't a thing. It draws itself
                as a `Kit.overlay`, so where in the document it sits stops mattering. --%>
          <AudiencePicker.picker
            :if={open_item(assigns)}
            statement={open_item(assigns).statement}
            context_label={world_title(@name)}
            audience={open_item(assigns).audience}
            groups={@picker_groups}
            people={@picker_people}
            resolved={Audience.resolve(open_item(assigns).audience)}
          />

          <%!-- The owner for the inline "add" control, which sits up in its own list
                inside `#bible-form`. It carries no markup of its own: a form element
                exists here only because one form cannot be nested in another, and the
                control points at it with `form="item-form"`. --%>
          <form id="item-form" phx-submit="add_item"></form>

          <%!-- ── Template or copy (§2.5b) ─────────────────────────────────── --%>
          <Kit.sheet class="m-4">
            <Kit.row class="px-4 py-3" style="background:var(--b2)">
              <span class="lbl dim">Reuse</span>
            </Kit.row>
            <Kit.row :if={@copied_from} class="px-4 py-2.5 flex items-start gap-2">
              <Kit.dot colour="var(--lamp)" class="mt-1.5 shrink-0" />
              <div>
                <p class="text-[12px] leading-relaxed">
                  This is a copy, with a history of its own. Editing it reaches nothing else.
                </p>
                <Kit.btn size={:sm} type="button" phx-click="save_to_library" class="mt-2">
                  Save a copy to your library
                </Kit.btn>
                <p class="text-[11px] leading-relaxed dim mt-1.5">
                  A snapshot of it as it is now, not a link back.
                </p>
              </div>
            </Kit.row>
            <div class="px-4 py-2.5 flex items-start gap-2">
              <Kit.dot colour="var(--bcm)" class="mt-1.5 shrink-0" />
              <p class="text-[12px] leading-relaxed dim">
                <%= reuse_line(@copy_count) %>
              </p>
            </div>
          </Kit.sheet>

          <%!-- ── Sharing ──────────────────────────────────────────────────── --%>
          <Kit.sheet class="m-4" id="sharing">
            <Kit.row class="px-4 py-3" style="background:var(--b2)">
              <span class="ttl text-[15px] font-semibold">Who can see <%= world_title(@name) %></span>
            </Kit.row>

            <button
              :for={{v, title, note} <- visibilities()}
              type="button"
              class={["row w-full px-4 py-2.5 flex items-start gap-2.5 text-left", v == @entry.visibility && "bg-[var(--b3)]"]}
              phx-click="set_visibility"
              phx-value-visibility={v}
              aria-pressed={to_string(v == @entry.visibility)}
            >
              <Kit.dot
                colour={if(v == @entry.visibility, do: "var(--lamp)", else: "var(--rule)")}
                class="mt-1.5"
              />
              <span>
                <span class="block text-[13px] font-semibold"><%= title %></span>
                <span class="block text-[11px] dim"><%= note %></span>
              </span>
            </button>

            <%!-- The token appears the moment it exists rather than being minted and
                  shown to nobody, which is what the design objected to. --%>
            <div :if={@entry.share_token} class="px-4 py-3">
              <div class="lbl dim mb-1.5">Share link</div>
              <div
                class="field px-3 py-2.5 mono text-[12px] leading-relaxed mb-2"
                style="word-break:break-all"
              >
                <%= share_url(@entry) %>
              </div>
              <Kit.btn
                kind={:pen}
                size={:sm}
                type="button"
                phx-click="rotate_link"
                data-confirm="A new link stops the old one working. Continue?"
              >
                New link
              </Kit.btn>
              <p class="text-[11px] leading-relaxed dim mt-2">A new link breaks the old one.</p>
            </div>
          </Kit.sheet>
        </div>

        <.save_bar {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  # One authored list — a rule, or something already true. Same component for both,
  # and the same secret control, because they are the same thing to a reader.
  attr(:field, :string, required: true)
  attr(:label, :string, required: true)
  attr(:add_label, :string, required: true)
  attr(:placeholder, :string, required: true)
  attr(:panel, :any, required: true)
  attr(:items, :list, required: true)
  attr(:generating, :any, required: true)
  attr(:last, :boolean, default: false)
  attr(:labels, :map, default: %{})

  defp item_list(assigns) do
    ~H"""
    <div class={[not @last && "row", "px-4 py-3"]} id={@field}>
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="flex items-center gap-1.5">
          <span class="lbl dim"><%= @label %></span>
          <Kit.info label="secrets" phx-click="drawer" phx-value-section="secrets" />
        </span>
        <Kit.btn
          size={:sm}
          type="button"
          phx-click="suggest_items"
          phx-value-field={@field}
          disabled={busy?(@generating, @field)}
        >
          <%= if busy?(@generating, @field), do: "✦ …", else: "✦ Suggest" %>
        </Kit.btn>
      </div>

      <p :if={@items == []} class="text-[13px] dim">Nothing yet.</p>

      <%!-- The menu opens **in the flow**, not as an absolutely-positioned layer. The
            kit's `.sheet` is `overflow:hidden` (it's what rounds the corners), so a
            floating panel was clipped by the sheet's bottom edge — which meant the
            last items in a list, the ones nearest that edge, were exactly the ones
            whose menus you couldn't read. It also matches how the mock draws a row
            menu (`ux/polyphony-campaign.html` §05 "Row menu"): a panel, not a layer.
            Opening the whole row rather than the ⋯ alone is the other half — a
            fourteen-pixel target is not a phone affordance. --%>
      <details :for={{item, i} <- Enum.with_index(@items)} class="py-1.5">
        <summary class="flex items-start gap-2 list-none cursor-pointer">
          <Kit.marked
            mark={if(item.concealed, do: :secret, else: :plain)}
            class="min-w-0 flex-1"
          >
            <span class="text-[13.5px] leading-relaxed"><%= item.statement %></span>
            <%!-- The audience is part of the item, not behind the picker, so the count
                  is readable without opening anything (§01). --%>
            <AudiencePicker.line
              :if={item.concealed}
              audience={item.audience}
              labels={@labels}
              class="mt-1"
            />
          </Kit.marked>
          <span class="pill shrink-0" aria-label={"Change item #{i + 1}"}>⋯</span>
        </summary>

        <nav class="sheet mt-1.5" style="background:var(--b2)">
            <button
              type="button"
              class="row w-full px-4 py-2.5 flex items-center justify-between gap-3 text-left"
              phx-click="toggle_secret"
              phx-value-field={@field}
              phx-value-index={i}
              aria-pressed={to_string(item.concealed)}
            >
              <span>
                <span class="block text-[13px] font-semibold">Secret</span>
                <span class="block text-[11px] dim">Kept out of every character's head</span>
              </span>
              <Kit.sw on={item.concealed} colour="var(--secret)" />
            </button>
            <%!-- Secret first, audience second: there is nothing to point at until
                  the item is marked. --%>
            <button
              :if={item.concealed}
              type="button"
              class="row w-full px-4 py-2.5 flex items-center justify-between gap-2 text-[13px] text-left"
              phx-click="open_audience"
              phx-value-field={@field}
              phx-value-index={i}
            >
              <span>Who knows this</span>
              <span class="dim"><%= knows_count(item.audience) %></span>
            </button>
            <button
              type="button"
              class="row w-full px-4 py-2.5 text-[13px] text-left"
              phx-click="move_item"
              phx-value-field={@field}
              phx-value-index={i}
              phx-value-by="-1"
            >
              Move up
            </button>
            <button
              type="button"
              class="row w-full px-4 py-2.5 text-[13px] text-left"
              phx-click="move_item"
              phx-value-field={@field}
              phx-value-index={i}
              phx-value-by="1"
            >
              Move down
            </button>
            <button
              type="button"
              class="w-full px-4 py-2.5 text-[13px] text-left"
              style="color:var(--pencil)"
              phx-click="remove_item"
              phx-value-field={@field}
              phx-value-index={i}
            >
              Delete
            </button>
        </nav>
      </details>

      <%!-- Adding happens **here**, in the list it adds to. It used to open a separate
            sheet below the whole bible form, far enough away that the two didn't
            obviously belong together — you pressed "Add something that's true…" and a
            panel appeared somewhere else on the page. Closed, this is the same box as
            before; open, that box is the input. --%>
      <button
        :if={@panel != @field}
        type="button"
        class="field px-3 py-2 text-[13px] dim w-full text-left mt-2"
        phx-click="panel"
        phx-value-panel={@field}
      >
        <%= @add_label %>
      </button>

      <div :if={@panel == @field} class="mt-2">
        <label for={"new-#{@field}"} class="sr-only"><%= @add_label %></label>
        <div class="flex gap-1.5">
          <%!-- `form=` rather than a nested `<form>`: this markup lives inside
                `#bible-form`, a form inside a form isn't a thing, and without an owner
                of its own Enter here would submit the *bible* and lose what was typed.
                HTML form association puts the control on `#item-form` (rendered empty,
                outside, below) wherever it happens to sit in the document.
                `phx-mounted` rather than `autofocus`, for the same class of reason:
                the attribute only fires on a page load, and this arrives by patch —
                it would look right in the markup and leave the caret nowhere. --%>
          <input
            id={"new-#{@field}"}
            form="item-form"
            type="text"
            name="statement"
            autocomplete="off"
            phx-mounted={JS.focus()}
            placeholder={@placeholder}
            class="field px-3 py-2.5 text-[13px] flex-1"
          />
          <input form="item-form" type="hidden" name="field" value={@field} />
          <Kit.btn kind={:primary} type="submit" form="item-form">Add</Kit.btn>
          <Kit.btn kind={:ghost} type="button" phx-click="panel" phx-value-panel="">
            Cancel
          </Kit.btn>
        </div>
        <p class="text-[11px] leading-relaxed dim mt-1.5">
          Everything starts public. Mark it secret from its own menu once it's on the list.
        </p>
      </div>
    </div>
    """
  end

  # The read-only preview (§3.2), rendered through the **same** filter the context
  # path uses — `WorldBible.for_character/1` — so this can't drift from what a
  # character's prompt actually contains.
  attr(:bible, :map, required: true)

  defp preview(assigns) do
    assigns = assign(assigns, :seen, WorldBible.for_character(assigns.bible))

    ~H"""
    <div class="flex-1 min-h-0 overflow-y-auto">
      <Kit.sheet class="m-4">
        <Kit.row
          class="px-4 py-2 flex items-center justify-between gap-2"
          style="background:color-mix(in srgb,var(--secret) 14%,transparent)"
        >
          <span class="text-[12.5px]">
            Previewing as <b>somebody with no part in this</b> · read-only
          </span>
        </Kit.row>

        <Kit.row :if={@bible.cover} class="px-4 py-3">
          <div class="lbl dim mb-1.5">Cover</div>
          <p class="text-[14px] leading-relaxed"><%= @bible.cover %></p>
        </Kit.row>

        <%!-- Paragraphs, not one run-on block: the field is stored blank-line
              separated and reads as prose, which is the point of previewing it. --%>
        <Kit.row :if={@seen.setting} class="px-4 py-3">
          <div class="lbl dim mb-1.5">Setting</div>
          <p :for={para <- paragraphs(@seen.setting)} class="text-[13.5px] leading-relaxed mb-2 last:mb-0">
            <%= para %>
          </p>
        </Kit.row>

        <Kit.row :if={@seen.tone} class="px-4 py-3">
          <div class="lbl dim mb-1.5">Tone</div>
          <p :for={para <- paragraphs(@seen.tone)} class="text-[13.5px] leading-relaxed mb-2 last:mb-0">
            <%= para %>
          </p>
        </Kit.row>

        <Kit.row :for={{label, list} <- preview_lists(@seen)} class="px-4 py-3">
          <div class="lbl dim mb-1.5"><%= label %></div>
          <div class="space-y-1.5 text-[13.5px] leading-relaxed">
            <div :for={s <- list}><%= s %></div>
          </div>
        </Kit.row>

        <div class="px-4 py-2.5">
          <p class="text-[11px] leading-relaxed dim"><%= hidden_line(@bible) %></p>
        </div>
      </Kit.sheet>
    </div>
    """
  end

  # The one info drawer, same shape as the character sheet's — title, prose, a
  # subsection per concept with its own dot.

  # The bar that doesn't scroll away, and its own comment two hundred lines up said why
  # it was needed: *"Save sits at the foot of a sheet several viewports tall and Name is
  # at its head, so the refusal rendered somewhere the author wasn't looking — pressing
  # Save read as nothing happening at all."* That was patched by also flashing the
  # clash; this puts the control itself where it can be seen.
  #
  # What it says is what is actually true. The prose autosaves — every edit calls
  # `touch/1` — so "unsaved changes" would be a lie most of the time. What only a
  # deliberate Save does here is run the **name-clash gate**: two worlds with one name
  # is the bug that made an interrupted Quick Build unsaveable, and a timer is not
  # entitled to decide a name is fine.
  defp save_bar(assigns) do
    ~H"""
    <div
      class="shrink-0 px-4 py-3 flex items-center gap-2"
      style="background:var(--b2);border-top:1px solid var(--rule)"
    >
      <div class="min-w-0 flex-1">
        <div :if={@name_error} class="text-[12.5px] leading-snug" style="color:var(--pencil)">
          <%= @name_error %>
        </div>
        <div :if={is_nil(@name_error) and @dirty} class="text-[12px] dim" role="status">
          Saving…
        </div>
        <div
          :if={is_nil(@name_error) and not @dirty and @saved}
          class="text-[12px]"
          style="color:var(--ok)"
          role="status"
        >
          ✓ Saved
        </div>
        <div :if={is_nil(@name_error) and not @dirty and not @saved} class="text-[12px] dim">
          Everything here is saved as you write.
        </div>
      </div>

      <%!-- Outside the form, submitting it by id — the alternative is a second form or
            a duplicate button inside the sheet, and both mean two Saves that can
            disagree about what was pressed. --%>
      <Kit.btn kind={:primary} type="submit" form="bible-form" class="shrink-0">Save</Kit.btn>
    </div>
    """
  end

  # Back to where you came from. Attaching a world **copies** it (§2.5b), so a bible
  # with a campaign belongs to that campaign alone and there is one right answer; a
  # library template has none, and keeps the library.
  defp back_to(nil), do: ~p"/library"
  defp back_to(campaign), do: ~p"/campaigns/#{campaign.id}"

  defp back_label(nil), do: "Back to library"

  defp back_label(campaign) do
    case String.trim(to_string(Map.get(Library.payload(campaign) || %{}, :name) || "")) do
      "" -> "Back to the campaign"
      name -> "Back to #{name}"
    end
  end

  # ── Render helpers ────────────────────────────────────────────────────────────

  # "Nothing written" is about the *world*, not the form: a name alone is a world
  # someone has started, and the first-run card should still be leading them in.
  defp empty_world?(assigns) do
    join_blocks(assigns.blocks["setting"]) == "" and join_blocks(assigns.blocks["tone"]) == "" and
      assigns.items["rules"] == [] and assigns.items["starting_canon"] == []
  end

  defp world_title(name) when name in [nil, ""], do: "Untitled world"
  defp world_title(name), do: name

  defp cover_action(_cover, true), do: "✦ …"
  defp cover_action(cover, _busy) when cover in [nil, ""], do: "✦ Write it"
  defp cover_action(_cover, _busy), do: "✦ Rewrite"

  defp secret_count(assigns),
    do: Enum.count(assigns.items["rules"] ++ assigns.items["starting_canon"], & &1.concealed)

  defp checked_line(1), do: "Checked against your 1 secret — it isn't mentioned."
  defp checked_line(n), do: "Checked against your #{n} secrets — none is mentioned."

  defp lineage_line(%{copied_from: nil, copy_count: 0}), do: "World"
  defp lineage_line(%{copied_from: nil, copy_count: 1}), do: "World · used in 1 campaign"
  defp lineage_line(%{copied_from: nil, copy_count: n}), do: "World · used in #{n} campaigns"
  defp lineage_line(_), do: "World · a copy"

  defp reuse_line(0),
    do:
      "Attaching this to a campaign gives that campaign its own copy. Nothing you write here " <>
        "afterwards reaches it."

  defp reuse_line(1),
    do:
      "One campaign was started from this. It has its own copy, so changes here only affect " <>
        "campaigns you start from now on."

  defp reuse_line(n),
    do:
      "#{n} campaigns were started from this. They have their own copies, so changes here only " <>
        "affect campaigns you start from now on."

  defp visibilities do
    [
      {"private", "Just me", "Nobody else can open it"},
      {"unlisted", "Anyone with the link", "Not listed, not searchable"},
      {"public", "Anyone", "Listed in Browse for people to find"}
    ]
  end

  defp share_url(entry), do: "#{PolyphonyWeb.Endpoint.url()}/s/#{entry.share_token}"

  defp panel_placeholder("rules"), do: "No magic. What looks like it is a bribe."
  defp panel_placeholder(_), do: "Nobody in Saltmarch has seen a customs inspector in nine years."

  # The entry whose audience is open, if any.
  defp open_item(%{audience_at: {field, index}} = assigns),
    do: Enum.at(assigns.items[field] || [], index)

  defp open_item(_assigns), do: nil

  defp knows_count(audience) do
    case length(Audience.resolve(audience)) do
      0 -> "nobody"
      n -> to_string(n)
    end
  end

  defp paragraphs(text), do: text |> to_string() |> to_blocks()

  defp preview_lists(seen) do
    [
      {"Rules", WorldBible.statements(seen.rules)},
      {"What's already true", WorldBible.statements(seen.starting_canon)}
    ]
    |> Enum.reject(fn {_l, list} -> list == [] end)
  end

  defp hidden_line(bible) do
    case length(WorldBible.secrets(bible)) do
      0 -> "There's nothing held back — this is the whole world."
      1 -> "One thing is held back. They have no idea."
      n -> "#{n} things are held back. They have no idea."
    end
  end
end
