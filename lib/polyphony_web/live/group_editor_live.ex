defmodule PolyphonyWeb.GroupEditorLive do
  @moduledoc """
  The group editor, ported from `ux/polyphony-campaign.html` §06b.

  Groups were built end to end in the domain — seeding, membership, secrets, arc
  fan-out — and had **no way to make one**. `Groups.create/3` and `update_fields/3`
  had no production callers, so the library's Groups tab listed things only a test
  could bring into existence, and the collapsed group card on arc review could never
  populate. This is the missing half.

  ## Written like a character, because it is one

  The design's own words: *a group is written like a character and used as a starting
  point for others*. So it takes the character sheet's shape — prose blocks with the
  same Rewrite/Expand, and a fact list with the same secret control — and drops the
  parts that only make sense for a person. No pronouns, no relationships, no
  boundaries: those belong to whoever gets written *from* it.

  ## Telling the members is a decision, not a save

  Editing the template reaches nobody. Seeding is a copy, so people written from this
  group already have their own facts, and current members are separate people with
  separate sheets. When a change should reach them, **Tell the members** fans it out
  (`Authoring.GroupArc`) as `1 + n` ordinary proposals — one against the group, one
  per member — every one of them through the same review gate as anything else.

  That it is a button rather than a consequence of saving is the point. Six members
  means six things you can say yes or no to, and refusing one is how you write the
  person who didn't go along with it.
  """
  use PolyphonyWeb, :live_view

  require Logger

  import PolyphonyWeb.BlockField

  alias Polyphony.{Groups, Library, Owner}
  alias Polyphony.Authoring.{ArcEntry, Autofill, Group, GroupArc}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  @prose_specs [
    {"premise", "What they are"},
    {"appearance", "How they read"},
    {"temperament", "How they behave"},
    {"backstory", "Where they came from"}
  ]
  @prose_fields Enum.map(@prose_specs, &elem(&1, 0))

  @stops [
    {"name", "Name"},
    {"premise", "What they are"},
    {"appearance", "How they read"},
    {"temperament", "How they behave"},
    {"backstory", "History"},
    {"facts", "What's true"},
    {"members", "Members"}
  ]

  defp prose_specs, do: @prose_specs
  defp stops, do: @stops

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == Group.kind() && not Library.hidden?(entry) do
      group = struct(Group, Map.from_struct(Library.payload(entry)))

      {:ok,
       socket
       |> assign(
         page_title: group.name || "Group",
         entry: entry,
         group: group,
         name: group.name || "",
         blocks: blocks_from_group(group),
         facts: group.facts || [],
         generating: MapSet.new(),
         saved: false,
         dirty: false,
         panel: nil,
         telling: nil
       )
       |> load_members()}
    else
      {:ok,
       socket
       |> put_flash(:error, "That group isn't here any more.")
       |> redirect(to: ~p"/library")}
    end
  end

  defp load_members(socket) do
    owner = Owner.of(socket.assigns.current_user)
    by_id = Map.new(Library.list_for_owner(owner), &{to_string(&1.id), &1})

    members =
      for id <- socket.assigns.group.member_ids || [],
          entry = by_id[to_string(id)],
          do: entry

    assign(socket, members: members, owner: owner)
  end

  # ── Editing ───────────────────────────────────────────────────────────────────

  def handle_event("sync", params, socket),
    do: {:noreply, socket |> assign_form(params) |> touch()}

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      socket = assign_form(socket, params)
      %{name: name, blocks: blocks, facts: facts, entry: entry} = socket.assigns

      group = %Group{
        socket.assigns.group
        | name: name,
          premise: join_blocks(blocks["premise"]),
          appearance: join_blocks(blocks["appearance"]),
          temperament: join_blocks(blocks["temperament"]),
          backstory: join_blocks(blocks["backstory"]),
          facts: facts
      }

      {:ok, _} = Groups.update_fields(entry.id, group)
      entry = Library.get(entry.id)

      {:noreply,
       socket
       |> assign(entry: entry, group: group, saved: true, dirty: false)
       |> load_members()}
    end)
  end

  def handle_event("add_block", %{"field" => f}, socket) when f in @prose_fields,
    do: {:noreply, update_blocks(socket, f, &(&1 ++ [""]))}

  def handle_event("remove_block", %{"field" => f, "index" => i}, socket)
      when f in @prose_fields,
      do: {:noreply, update_blocks(socket, f, &drop_block(&1, String.to_integer(i)))}

  # ── Facts (§04's one control, third place) ────────────────────────────────────

  def handle_event("panel", %{"panel" => panel}, socket),
    do:
      {:noreply,
       assign(socket,
         panel: if(panel == "" or socket.assigns.panel == panel, do: nil, else: panel)
       )}

  def handle_event("add_fact", %{"statement" => statement}, socket) do
    safe(socket, fn ->
      case String.trim(statement) do
        "" ->
          {:noreply, put_flash(socket, :error, "Write it first.")}

        text ->
          facts = socket.assigns.facts ++ [%Fact{statement: text}]
          {:noreply, socket |> assign(facts: facts, panel: nil) |> touch()}
      end
    end)
  end

  def handle_event("remove_fact", %{"index" => i}, socket) do
    facts = List.delete_at(socket.assigns.facts, String.to_integer(i))
    {:noreply, socket |> assign(facts: facts) |> touch()}
  end

  def handle_event("toggle_secret", %{"index" => i}, socket) do
    idx = String.to_integer(i)

    facts =
      List.update_at(socket.assigns.facts, idx, &%Fact{&1 | concealed: not &1.concealed})

    {:noreply, socket |> assign(facts: facts) |> touch()}
  end

  # ── Membership ────────────────────────────────────────────────────────────────

  def handle_event("remove_member", %{"id" => id}, socket) do
    safe(socket, fn ->
      {:ok, _} = Groups.remove_member(socket.assigns.entry.id, id)
      {:noreply, reload_group(socket)}
    end)
  end

  # ── Telling the members (§3.0b) ───────────────────────────────────────────────

  def handle_event("tell", %{"index" => i}, socket),
    do: {:noreply, assign(socket, telling: String.to_integer(i))}

  def handle_event("cancel_tell", _params, socket), do: {:noreply, assign(socket, telling: nil)}

  # The fan-out this whole subsystem was built for, and the call `GroupArc.fan_out/3`
  # never had. One statement becomes `1 + n` proposals — the group's own, and one per
  # current member — each through the ordinary review gate, so refusing one member's is
  # how you write the person who didn't go along with it.
  def handle_event("tell_members", %{"index" => i}, socket) do
    safe(socket, fn ->
      fact = Enum.at(socket.assigns.facts, String.to_integer(i))

      cond do
        is_nil(fact) ->
          {:noreply, assign(socket, telling: nil)}

        socket.assigns.members == [] ->
          {:noreply,
           socket
           |> assign(telling: nil)
           |> put_flash(:error, "Nobody is in this group yet.")}

        true ->
          entry = %ArcEntry{
            kind: :revision,
            statement: fact.statement,
            reason: "The #{socket.assigns.name} changed."
          }

          %{members: members} = GroupArc.fan_out(socket.assigns.entry.id, entry)

          {:noreply,
           socket
           |> assign(telling: nil)
           |> put_flash(
             :info,
             "Proposed to #{length(members)} member(s) — review them before they land."
           )}
      end
    end)
  end

  # ── Generation ────────────────────────────────────────────────────────────────

  def handle_event("generate_all", %{"brief" => brief}, socket) do
    safe(socket, fn ->
      {:noreply,
       socket
       |> mark("all", true)
       |> start_async(:gen_all, fn ->
         # A group is character-shaped, so it generates down the character path and
         # keeps the fields it has a home for. `name` here is the collective's.
         Autofill.generate_all(:character, group_brief(brief), %{}, [])
       end)}
    end)
  end

  def handle_async(:gen_all, {:ok, {:ok, values}}, socket) do
    blocks =
      Enum.reduce(values, socket.assigns.blocks, fn {f, v}, acc ->
        if f in @prose_fields, do: Map.put(acc, f, to_blocks(v)), else: acc
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]

    {:noreply, socket |> assign(name: name, blocks: blocks) |> mark("all", false) |> touch()}
  end

  def handle_async(:gen_all, result, socket) do
    Logger.warning("[group] generate-all failed: #{inspect(result)}")

    {:noreply,
     socket |> mark("all", false) |> put_flash(:error, "Couldn't write that. Try again.")}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp group_brief(brief),
    do: "A group, not a person — a crew, a household, an order. #{brief}"

  defp reload_group(socket) do
    entry = Library.get(socket.assigns.entry.id)
    group = struct(Group, Map.from_struct(Library.payload(entry)))

    socket |> assign(entry: entry, group: group) |> load_members()
  end

  # `b_<field>` is `block_field/1`'s own naming — the same convention the sheet and
  # bible editors read back, so one component means one parameter shape everywhere.
  defp assign_form(socket, params) do
    blocks =
      Map.new(@prose_fields, fn f ->
        {f, param_blocks(params["b_#{f}"], socket.assigns.blocks[f])}
      end)

    assign(socket, name: params["name"] || socket.assigns.name, blocks: blocks)
  end

  defp blocks_from_group(group),
    do: Map.new(@prose_fields, fn f -> {f, to_blocks(Map.get(group, String.to_atom(f)))} end)

  defp update_blocks(socket, field, fun),
    do:
      socket
      |> assign(blocks: Map.update!(socket.assigns.blocks, field, fun))
      |> touch()

  defp touch(socket), do: assign(socket, dirty: true, saved: false)

  defp mark(socket, key, on?) do
    set = socket.assigns.generating
    assign(socket, generating: if(on?, do: MapSet.put(set, key), else: MapSet.delete(set, key)))
  end

  defp secrets(facts), do: Enum.count(facts, & &1.concealed)

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title={@name} eyebrow="Group" back={~p"/library"} back_label="Back to library">
        <:actions>
          <Kit.pill><%= length(@members) %> in it</Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.jump class="shrink-0">
        <:stop :for={{id, label} <- stops()}>
          <a href={"##{id}"}><%= label %></a>
        </:stop>
      </Kit.jump>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <Kit.sheet class="m-4" style="border-color:var(--lamp)">
          <Kit.row class="px-4 py-3" style="background:var(--b2)">
            <span class="lbl dim">Write it from a line</span>
          </Kit.row>
          <div class="px-4 py-3">
            <form id="group-generate-all" phx-submit="generate_all">
              <label for="brief" class="sr-only">Describe the group</label>
              <textarea
                id="brief"
                name="brief"
                rows="2"
                placeholder="The harbour watch — half constabulary, half smugglers…"
                class="field px-3 py-2.5 text-[13px] leading-relaxed w-full mb-2"
              ></textarea>
              <Kit.btn kind={:primary} type="submit" disabled={busy?(@generating, "all")}>
                <%= if busy?(@generating, "all"), do: "✦ …", else: "✦ Write the group" %>
              </Kit.btn>
            </form>
          </div>
        </Kit.sheet>

        <form id="group-form" phx-submit="save" phx-change="sync">
          <Kit.sheet class="m-4">
            <div class="row px-4 py-3" id="name">
              <label for="group-name" class="lbl dim">Name</label>
              <input
                id="group-name"
                type="text"
                name="name"
                value={@name}
                phx-debounce="600"
                placeholder="The Tidewatch"
                class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
              />
            </div>

            <.block_field
              :for={{f, label} <- prose_specs()}
              id={f}
              field={f}
              label={label}
              blocks={@blocks[f]}
              generating={@generating}
            />

            <%!-- The same control as a world's rules and a character's facts (§04),
                  because to a reader they are the same thing: something true that may
                  or may not be known. Here it is also what membership *grants* — this
                  is the list a secret pointed at the group resolves to. --%>
            <div class="px-4 py-3" id="facts">
              <div class="flex items-center justify-between gap-2 mb-2">
                <span class="lbl dim">What's true about them</span>
                <span class="lbl dim"><%= secrets(@facts) %> secret</span>
              </div>

              <p :if={@facts == []} class="text-[13px] dim">Nothing yet.</p>

              <details :for={{fact, i} <- Enum.with_index(@facts)} class="py-1.5" id={"fact-#{i}"}>
                <summary class="flex items-start gap-2 list-none cursor-pointer">
                  <Kit.marked
                    mark={if(fact.concealed, do: :secret, else: :plain)}
                    class="min-w-0 flex-1"
                  >
                    <span class="text-[13.5px] leading-relaxed"><%= fact.statement %></span>
                  </Kit.marked>
                  <span class="pill shrink-0" aria-label={"Change item #{i + 1}"}>⋯</span>
                </summary>

                <nav class="sheet mt-1.5" style="background:var(--b2)">
                  <button
                    type="button"
                    class="row w-full px-4 py-2.5 flex items-center justify-between gap-3 text-left"
                    phx-click="toggle_secret"
                    phx-value-index={i}
                    aria-pressed={to_string(fact.concealed)}
                  >
                    <span>
                      <span class="block text-[13px] font-semibold">Secret</span>
                      <span class="block text-[11px] dim">
                        Only people this group's membership lets in on it
                      </span>
                    </span>
                    <Kit.sw on={fact.concealed} colour="var(--secret)" />
                  </button>
                  <button
                    type="button"
                    class="row w-full px-4 py-2.5 text-[13px] text-left"
                    phx-click="tell"
                    phx-value-index={i}
                  >
                    Tell the members
                    <span class="block text-[11px] dim">
                      Proposes it to each of them, one review at a time
                    </span>
                  </button>
                  <button
                    type="button"
                    class="w-full px-4 py-2.5 text-[13px] text-left"
                    style="color:var(--pencil)"
                    phx-click="remove_fact"
                    phx-value-index={i}
                  >
                    Delete
                  </button>
                </nav>
              </details>

              <button
                :if={@panel != "facts"}
                type="button"
                class="field px-3 py-2 text-[13px] dim w-full text-left mt-2"
                phx-click="panel"
                phx-value-panel="facts"
              >
                Add something that's true…
              </button>

              <div :if={@panel == "facts"} class="mt-2">
                <label for="new-fact" class="sr-only">Add something that's true</label>
                <div class="flex gap-1.5">
                  <%!-- Owned by its own form, like the bible editor's: this sits inside
                        `#group-form` and a form can't nest, so without it Enter would
                        save the group and lose what was typed. --%>
                  <input
                    id="new-fact"
                    form="group-fact-form"
                    type="text"
                    name="statement"
                    autocomplete="off"
                    phx-mounted={JS.focus()}
                    placeholder="They keep the tide bell, and the ledger under it."
                    class="field px-3 py-2.5 text-[13px] flex-1"
                  />
                  <Kit.btn kind={:primary} type="submit" form="group-fact-form">Add</Kit.btn>
                  <Kit.btn kind={:ghost} type="button" phx-click="panel" phx-value-panel="">
                    Cancel
                  </Kit.btn>
                </div>
              </div>
            </div>
          </Kit.sheet>

          <div class="mx-4 mb-4 flex items-center gap-2">
            <Kit.btn kind={:primary} type="submit">Save</Kit.btn>
            <span :if={@saved} class="text-[12px]" style="color:var(--ok)" role="status">
              ✓ Saved
            </span>
          </div>
        </form>

        <form id="group-fact-form" phx-submit="add_fact"></form>

        <.tell_panel :if={@telling} {assigns} />

        <Kit.sheet class="m-4" id="members">
          <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="lbl dim">Members · <%= length(@members) %></span>
          </Kit.row>

          <Kit.row :for={m <- @members} class="px-4 py-2.5 flex items-center gap-2.5">
            <span class="av shrink-0" style={"background:#{Voice.of_sheet(Library.payload(m))}"}></span>
            <div class="min-w-0 flex-1">
              <.link navigate={~p"/authoring/character/#{m.id}"} class="text-[13.5px] font-semibold">
                <%= member_name(m) %>
              </.link>
            </div>
            <Kit.btn kind={:pen} size={:sm} phx-click="remove_member" phx-value-id={m.id}>
              Remove
            </Kit.btn>
          </Kit.row>

          <%!-- Joining is done from the person's own sheet, where the question "who is
                this?" is already on screen. Two places to do one thing is how they
                drift. --%>
          <Kit.empty :if={@members == []} headline="Nobody is in it yet." class="py-6">
            A character joins from their own sheet. An empty group is still useful —
            it's how you set a trap before anyone walks into it.
          </Kit.empty>
        </Kit.sheet>
      </div>
    </Kit.frame>
    """
  end

  defp tell_panel(assigns) do
    assigns = assign(assigns, :fact, Enum.at(assigns.facts, assigns.telling))

    ~H"""
    <Kit.sheet :if={@fact} class="mx-4 mb-4" style="border-color:var(--lamp)">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold">Tell the members</span>
      </Kit.row>
      <div class="px-4 py-3">
        <p class="text-[13px] leading-relaxed mb-2">“<%= @fact.statement %>”</p>
        <p class="text-[12px] leading-relaxed dim mb-3">
          <%= length(@members) %> member(s) each get this as a proposal, plus one against
          the group itself. Nothing changes until you accept it, and refusing one is how
          you write the person who didn't go along with it.
        </p>
        <div class="flex gap-1.5">
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="tell_members" phx-value-index={@telling}>
            Propose it
          </Kit.btn>
          <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="cancel_tell">Cancel</Kit.btn>
        </div>
      </div>
    </Kit.sheet>
    """
  end

  defp member_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Unnamed (##{entry.id})"
    end
  end
end
