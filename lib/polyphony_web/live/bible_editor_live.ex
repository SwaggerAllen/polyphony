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
  alias PolyphonyWeb.{AudiencePicker, Autosave, Generating, Guard, Screens}

  # Prose, edited as paragraph blocks.
  @prose_specs [{"setting", "Setting"}, {"tone", "Tone"}]
  @prose_fields Enum.map(@prose_specs, &elem(&1, 0))

  @list_specs [
    {"rules", "Rules", "Add a rule…"},
    {"starting_canon", "What's already true", "Add something that's true…"}
  ]

  @list_fields Enum.map(@list_specs, &elem(&1, 0))

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
         knows_counts: knows_counts(items_from_bible(bible)),
         knows_counts: knows_counts(items_from_bible(bible)),
         gen_subject: entry.id,
         generating: MapSet.new(),
         saved: false,
         dirty: false,
         autosave_ref: nil,
         drawer: nil,
         panel: nil,
         preview: false,
         seen: nil,
         draft: nil,
         resolved_audience: [],
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
    preview? = params["preview"] == "1"

    {:noreply,
     socket
     |> assign(
       panel: present(params["panel"]),
       drawer: present(params["drawer"]),
       preview: preview?,
       audience_at: decode_audience(params["audience"])
     )
     |> assign_audience()
     |> assign_preview(preview?)}
  end

  # The preview filters the **draft** — what's on the form, not what's saved — through
  # the same call the context path uses, so an author previews what a character's prompt
  # will actually contain. Filtering walks audiences, so it happens here rather than in
  # the markup, and only when the preview is open.
  defp assign_preview(socket, false), do: assign(socket, seen: nil, draft: nil)

  defp assign_preview(socket, true) do
    # Both halves: the draft carries the cover and the count of what's held back, and
    # `seen` is that same draft filtered to what a character would be told.
    draft = Screens.BibleEditor.draft_bible(socket.assigns)
    assign(socket, draft: draft, seen: WorldBible.for_character(draft))
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
      bible = Screens.BibleEditor.draft_bible(socket.assigns)
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
     |> assign(name: name, blocks: blocks, items: items, knows_counts: knows_counts(items))
     |> assign_audience()
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
        items: items_from_bible(bible),
        knows_counts: knows_counts(items_from_bible(bible))
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

  # The one place items change, so the two things derived from them are refreshed here
  # rather than at each call site: the per-item counts, and the resolved line inside an
  # open picker — ticking a group has to say who that means *now*.
  defp update_items(socket, field, fun) do
    items = Map.put(socket.assigns.items, field, fun.(socket.assigns.items[field]))

    socket
    |> assign(items: items, knows_counts: knows_counts(items))
    |> assign_audience()
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
        subject: Screens.BibleEditor.draft_bible(socket.assigns),
        opts: gen_opts(socket)
      })
    else
      socket
    end
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

  # Resolving an audience walks group membership, so doing it per item inside the markup
  # was a read for every rule and every canon entry on every render. Counted once here,
  # keyed the way the markup asks for it.
  defp knows_counts(items) do
    for {field, list} <- items,
        {item, i} <- Enum.with_index(list),
        into: %{} do
      {{field, i}, knows_count(item.audience)}
    end
  end

  defp knows_count(audience) do
    case length(Audience.resolve(audience)) do
      0 -> "nobody else"
      n -> to_string(n)
    end
  end

  def render(assigns) do
    ~H"""
    <Screens.BibleEditor.screen
      current_user={@current_user}
      entry={@entry}
      campaign={@campaign && %{id: @campaign.id, name: campaign_name(@campaign)}}
      name={@name}
      name_error={@name_error}
      name_clash={@name_clash}
      blocks={@blocks}
      items={@items}
      knows_counts={@knows_counts}
      cover={@cover}
      copied_from={@copied_from}
      copy_count={@copy_count}
      seen={@seen}
      draft={@draft}
      preview={@preview}
      generating={@generating}
      panel={@panel}
      drawer={@drawer}
      brief_open={@brief_open}
      dirty={@dirty}
      saved={@saved}
      picker_groups={@picker_groups}
      picker_people={@picker_people}
      picker_labels={@picker_labels}
      resolved_audience={@resolved_audience}
      audience_at={@audience_at}
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

  # Derived from `items` **and** `audience_at`, so it is recomputed wherever either
  # moves — an edit changes the list without a patch, and the resolved line has to say
  # who that means *now* rather than who it meant when the picker opened.
  defp assign_audience(socket),
    do: assign(socket, resolved_audience: resolved_audience(socket, socket.assigns[:audience_at]))

  defp resolved_audience(socket, {field, index}) do
    case Enum.at(socket.assigns.items[field] || [], index) do
      nil -> []
      item -> Audience.resolve(item.audience)
    end
  end

  defp resolved_audience(_socket, _), do: []
end
