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

  alias Polyphony.{Campaigns, Groups, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{ArcEntry, Group, GroupArc}
  alias Polyphony.Authoring.CharacterSheet.Fact
  alias Polyphony.Permissions
  alias Polyphony.Permissions
  import PolyphonyWeb.BlockField

  alias PolyphonyWeb.{Autosave, Generating, Guard, Screens, Voice}

  @prose_specs [
    {"premise", "What they are"},
    {"appearance", "How they read"},
    {"temperament", "How they behave"},
    {"backstory", "Where they came from"}
  ]
  @prose_fields Enum.map(@prose_specs, &elem(&1, 0))

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    if entry && entry.kind == Group.kind() &&
         Permissions.can_edit?(entry, socket.assigns.current_user) do
      group = struct(Group, Map.from_struct(Library.payload(entry)))

      {:ok,
       socket
       |> assign(
         page_title: group.name || "Group",
         entry: entry,
         group: group,
         campaign:
           Campaigns.of_world(Owner.of(socket.assigns.current_user), group.world_bible_id),
         name: group.name || "",
         blocks: blocks_from_group(group),
         facts: group.facts || [],
         gen_subject: entry.id,
         generating: MapSet.new(),
         saved: false,
         dirty: false,
         autosave_ref: nil,
         panel: nil,
         telling: nil
       )
       |> Generating.restore()
       |> load_members()}
    else
      Guard.refuse(socket, entry, "Group", socket.assigns.current_user)
    end
  end

  defp load_members(socket) do
    owner = Owner.of(socket.assigns.current_user)
    by_id = Map.new(Library.list_for_owner(owner), &{to_string(&1.id), &1})

    # `%{id, name, hue}` rather than library entries: the screen renders from assigns and
    # may not read the library (see `PolyphonyWeb.Screens`). It used to resolve a payload
    # per row, for a name and an avatar colour.
    members =
      for id <- socket.assigns.group.member_ids || [],
          entry = by_id[to_string(id)],
          payload = Library.payload(entry),
          do: %{id: entry.id, name: member_name(entry.id, payload), hue: Voice.of_sheet(payload)}

    assign(socket, members: members, owner: owner)
  end

  @doc false
  # The open panel lives in the **URL** rather than in the socket — see
  # `BibleEditorLive.handle_params/3` for why, and for what it buys on a phone.
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, panel: present(params["panel"]))}

  defp view_patch(socket, changes) do
    params =
      %{"panel" => socket.assigns.panel}
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {_k, v} -> v in [nil, false, ""] end)

    push_patch(socket, to: ~p"/authoring/group/#{socket.assigns.entry.id}?#{params}")
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value

  # ── Editing ───────────────────────────────────────────────────────────────────

  def handle_event("sync", params, socket),
    do: {:noreply, socket |> assign_form(params) |> touch()}

  def handle_event("save", params, socket) do
    safe(socket, fn ->
      socket = socket |> assign_form(params) |> Autosave.cancel()
      {:noreply, load_members(persist(socket))}
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
       view_patch(socket,
         panel: if(panel == "" or socket.assigns.panel == panel, do: nil, else: panel)
       )}

  def handle_event("add_fact", %{"statement" => statement}, socket) do
    safe(socket, fn ->
      case String.trim(statement) do
        "" ->
          {:noreply, put_flash(socket, :error, "Write it first.")}

        text ->
          facts = socket.assigns.facts ++ [%Fact{statement: text}]
          {:noreply, socket |> assign(facts: facts) |> touch() |> view_patch(panel: nil)}
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
       # A group is character-shaped, so it generates down the character path and
       # keeps the fields it has a home for. `name` here is the collective's.
       |> Generating.request("all", "autofill.all", %{
         kind: :character,
         brief: group_brief(brief),
         current: %{},
         opts: []
       })}
    end)
  end

  def handle_info({:generation, "all", {:ok, values}}, socket) do
    blocks =
      Enum.reduce(values, socket.assigns.blocks, fn {f, v}, acc ->
        if f in @prose_fields, do: Map.put(acc, f, to_blocks(v)), else: acc
      end)

    name = if values["name"] in [nil, ""], do: socket.assigns.name, else: values["name"]

    {:noreply, socket |> assign(name: name, blocks: blocks) |> mark("all", false) |> touch()}
  end

  def handle_info({:generation, key, result}, socket) do
    Logger.warning("[group] generation failed (#{key}): #{inspect(result)}")

    {:noreply, socket |> mark(key, false) |> put_flash(:error, "Couldn't write that. Try again.")}
  end

  # A group has no gate on any of its fields, so the quiet write and the deliberate one
  # are the same write — Save only differs in flushing now and reloading the roster.
  def handle_info(:autosave, socket), do: {:noreply, persist(socket)}

  def terminate(_reason, socket), do: Autosave.flush(socket, &persist/1)

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
    do: Map.new(@prose_fields, fn f -> {f, to_blocks(Map.get(group, field_atom(f)))} end)

  # `to_existing_atom`, as the bible editor already does it. The field names here are a
  # compile-time list so nothing untrusted reaches it either way — but `String.to_atom`
  # on anything derived from a parameter is how the atom table gets exhausted, and
  # sobelow is right to refuse to distinguish the safe uses from the unsafe ones.
  defp field_atom(f), do: String.to_existing_atom(f)

  defp update_blocks(socket, field, fun),
    do:
      socket
      |> assign(blocks: Map.update!(socket.assigns.blocks, field, fun))
      |> touch()

  defp persist(socket) do
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

    socket
    |> assign(entry: Library.get(entry.id), group: group)
    |> Autosave.saved()
  end

  defp touch(socket), do: Autosave.touch(socket)

  defp mark(socket, key, on?) do
    set = socket.assigns.generating
    assign(socket, generating: if(on?, do: MapSet.put(set, key), else: MapSet.delete(set, key)))
  end

  defp member_name(_id, %{name: n}) when is_binary(n) and n != "", do: n
  defp member_name(id, _payload), do: "Unnamed (##{id})"

  def render(assigns) do
    ~H"""
    <Screens.GroupEditor.screen
      blocks={@blocks}
      campaign={@campaign && %{id: @campaign.id, name: campaign_name(@campaign)}}
      current_user={@current_user}
      facts={@facts}
      dirty={@dirty}
      saved={@saved}
      generating={@generating}
      members={@members}
      name={@name}
      panel={@panel}
      telling={@telling}
    />
    """
  end

  # The one field the group editor needs off the campaign entry, resolved here so the
  # screen can stay a function of assigns.
  defp campaign_name(campaign) do
    case String.trim(to_string(Map.get(Library.payload(campaign) || %{}, :name) || "")) do
      "" -> nil
      name -> name
    end
  end
end
