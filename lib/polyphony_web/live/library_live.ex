defmodule PolyphonyWeb.LibraryLive do
  @moduledoc """
  The library, ported from `ux/polyphony-library.html` — *your stuff*.

  Not a create hub any more; that's the campaign's job. This is where you find what
  you already have, and it's where the archive and the trash finally get a front door.

  ## One create button

  **New campaign is the only create action.** Worlds and characters are made *inside*
  a campaign, so the library has one button rather than three and the three-way "what
  do I make first" question disappears. First run says the same thing with one button
  and no taxonomy lesson — you don't need to know about worlds and characters to
  start, because the campaign will ask.

  ## The grouping is free

  Characters don't cross campaigns (§2.7), so every one belongs to exactly **one** —
  which makes grouping people by campaign a fact rather than a judgement call, and
  keeps the list navigable at forty walk-ons. Tier filters (§2.5) do the rest;
  walk-ons collapse behind a count, because they're the tier you scan past.

  ## Worlds are templates, not dependencies

  Attaching a world to a campaign **copies** it (§2.5b), because a campaign writes its
  own history onto its world. So a row says how many campaigns *started from* it —
  past tense, no live coupling, and nothing an edit here can break downstream.

  ## The recovery window is a number

  Archive and trash are deliberately different shelves. **Archived** is filing:
  reversible, out of the way, saying nothing about the story. **Trash** is on a clock,
  and the countdown is the whole point — it's the only place the recovery window is a
  number rather than a claim (§2.13), which is true only because
  `Polyphony.Jobs.PurgeTrash` actually arrives at the end of it.

  ## Visibility is shown here, set elsewhere

  Changing who can see something belongs next to the thing itself — you decide a world
  is ready to share while looking at the world, not while scanning a list. The library
  wears the badge; the editors own the control.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Campaigns, Characters, Groups, Library, Owner, Reading}
  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Reading.Session
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  @tabs ~w(campaigns reading worlds people groups shelves)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Library", query: "", tier: "all")
     |> assign(owner: Owner.of(socket.assigns.current_user))
     |> load()}
  end

  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "campaigns"
    {:noreply, assign(socket, tab: tab)}
  end

  # ── Loading ──────────────────────────────────────────────────────────────────

  defp load(socket) do
    owner = socket.assigns.owner
    entries = Library.list_for_owner(owner)

    socket
    |> assign(entries: entries)
    |> assign(campaigns: campaign_rows(entries))
    |> assign(worlds: world_rows(entries))
    |> assign(people: people_groups(owner, entries))
    |> assign(groups: group_rows(owner, entries))
    |> assign(reading: owner |> Reading.shelf() |> Enum.map(&decorate_reading/1))
    |> assign(archived: Library.archived(owner), trashed: Library.trash(owner))
  end

  # A campaign row carries enough to pick up where you left off: where it is in its
  # life (§2.5c), its world and its size, and what's waiting for review — the same
  # number the scene gate will stop them with, so the row doesn't surprise anyone.
  defp campaign_rows(entries) do
    by_id = Map.new(entries, &{&1.id, &1})

    entries
    |> Enum.filter(&Campaigns.campaign?/1)
    |> Enum.map(&campaign_row(&1, by_id))
    # The open one is what you came back for, so it's first; the one you never opened
    # is last, because it's the least likely thing you're looking for.
    |> Enum.sort_by(&{status_rank(&1), String.downcase(&1.name)})
  end

  defp status_rank(%{status: :playing}), do: 0
  defp status_rank(%{published?: true}), do: 1
  defp status_rank(%{status: :finished}), do: 2
  defp status_rank(_), do: 3

  defp campaign_row(entry, by_id) do
    payload = Library.payload(entry) || %{}
    status = Campaigns.status(payload)

    %{
      id: entry.id,
      name: Campaigns.name(entry),
      named?: named?(payload),
      status: status,
      status_label: Campaigns.status_label(status),
      # Publishing freezes a *copy*, so the campaign here is still live and playable —
      # what's published is a separate entry descended from it (§3.1d).
      published?: Library.published?(entry),
      world: world_name(by_id, payload),
      people: length(Map.get(payload, :character_ids) || []),
      scenes: length(Map.get(payload, :scenes) || []),
      premise: blank_to_nil(Map.get(payload, :premise)),
      pending: Campaigns.pending_review(entry),
      copies:
        entry.id
        |> Library.publications_of()
        |> Enum.map(&Library.copy_count(&1.id))
        |> Enum.sum()
    }
  end

  # **Templates only.** Attaching a world copies it into the same library (§2.5b), so
  # without this the tab would list every campaign's working copy beside the thing it
  # was copied from — the same name three times, two of which belong to a campaign and
  # aren't separately editable in any meaningful sense. A campaign's copy is reached
  # through the campaign; the library keeps the templates.
  defp world_rows(entries) do
    attached = attached_bibles(entries)

    for entry <- entries, entry.kind == "world_bible", not MapSet.member?(attached, entry.id) do
      payload = Library.payload(entry) || %{}

      %{
        id: entry.id,
        name: entry_name(entry),
        named?: named?(payload),
        visibility: entry.visibility,
        blurb: blank_to_nil(Map.get(payload, :cover)) || blank_to_nil(Map.get(payload, :premise)),
        started: started_from(entry.id, attached)
      }
    end
  end

  defp attached_bibles(entries) do
    for entry <- entries,
        Campaigns.campaign?(entry),
        id = to_int(Map.get(Library.payload(entry) || %{}, :bible_id)),
        into: MapSet.new(),
        do: id
  end

  # Past tense, and a count of departures rather than dependants: how many campaigns
  # took a copy of this world. Direct descent only — a campaign that forked another
  # campaign's copy started from *that*, not from here.
  defp started_from(world_id, attached) do
    world_id
    |> Library.copies_of()
    |> Enum.count(&MapSet.member?(attached, &1.id))
  end

  # Grouped by campaign, then by tier within it — the design's order, and the reason
  # the list survives forty walk-ons. Someone in no campaign yet gets a trailing group
  # rather than disappearing.
  defp people_groups(owner, entries) do
    by_character = Campaigns.by_character(owner)
    characters = Enum.filter(entries, &(&1.kind == "character"))

    characters
    |> Enum.group_by(&Map.get(by_character, to_string(&1.id)))
    |> Enum.map(fn {campaign, members} ->
      %{
        campaign: campaign && Campaigns.name(campaign),
        campaign_id: campaign && campaign.id,
        people: Enum.map(members, &person_row/1)
      }
    end)
    |> Enum.sort_by(&{is_nil(&1.campaign), &1.campaign || ""})
  end

  defp person_row(entry) do
    sheet = Library.payload(entry) || %{}
    tier = Characters.tier_of(entry)

    %{
      id: entry.id,
      name: entry_name(entry),
      role: blank_to_nil(Map.get(sheet, :premise)),
      tier: tier,
      tier_label: CharacterSheet.tier_label(tier),
      colour: Voice.of_sheet(sheet)
    }
  end

  defp group_rows(owner, entries) do
    by_character = Campaigns.by_character(owner)
    campaigns = Map.new(entries, &{&1.id, &1})

    owner
    |> Groups.list()
    |> Enum.map(fn entry ->
      group = Library.payload(entry) || %{}
      members = Map.get(group, :member_ids) || []

      %{
        id: entry.id,
        name: entry_name(entry),
        members: length(members),
        secrets: length(secrets_of(group)),
        colour: Voice.of_sheet(group),
        campaign: campaign_of_members(members, by_character, campaigns)
      }
    end)
    |> Enum.group_by(& &1.campaign)
    |> Enum.map(fn {campaign, rows} -> %{campaign: campaign, groups: rows} end)
    |> Enum.sort_by(&{is_nil(&1.campaign), &1.campaign || ""})
  end

  defp secrets_of(%Group{} = group), do: Group.secrets(group)
  defp secrets_of(_), do: []

  # A reading row needs two names the bookmark deliberately doesn't store: who wrote
  # it, and who you were reading as. Both are resolved at the edge — the bookmark
  # routes by id, the same rule that holds in visibility and membership — and both
  # come from the **published snapshot**, never the author's live library.
  defp decorate_reading(row) do
    Map.merge(row, %{
      author: author_of(row.source),
      perspective: Reading.perspective_label(row.bookmark, snapshot_names(row.source))
    })
  end

  defp author_of(nil), do: nil

  defp author_of(%{owner_type: "user", owner_id: id}) do
    case Polyphony.Accounts.get(id) do
      %{username: name} when is_binary(name) and name != "" -> "@" <> name
      _ -> nil
    end
  end

  defp author_of(_), do: nil

  defp snapshot_names(nil), do: %{}

  defp snapshot_names(source) do
    case Library.payload(source) do
      %{characters: characters} when is_list(characters) ->
        Map.new(characters, fn c ->
          {to_string(Map.get(c, :source_id)), Map.get(c[:sheet] || %{}, :name)}
        end)

      _ ->
        %{}
    end
  end

  # A group has no campaign field — it belongs wherever its members do, which is
  # unambiguous because they can't cross campaigns.
  defp campaign_of_members(members, by_character, campaigns) do
    Enum.find_value(members, fn id ->
      case Map.get(by_character, to_string(id)) do
        nil -> nil
        c -> Campaigns.name(Map.get(campaigns, c.id, c))
      end
    end)
  end

  defp world_name(by_id, payload) do
    case Map.get(payload, :bible_id) || Map.get(payload, :world_bible_id) do
      nil -> nil
      id -> with entry when not is_nil(entry) <- Map.get(by_id, to_int(id)), do: entry_name(entry)
    end
  end

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  # ── Filtering ────────────────────────────────────────────────────────────────

  # Search and tier both narrow the *people* tab; everything else is short enough that
  # structure does the work (§2.15 — search over the whole library is deliberately
  # later, when a real library gets long).
  defp shown_people(assigns) do
    q = assigns.query |> to_string() |> String.trim() |> String.downcase()

    for group <- assigns.people,
        people = Enum.filter(group.people, &match_person?(&1, q, assigns.tier)),
        people != [],
        do: %{
          group
          | people: Enum.sort_by(people, &{tier_rank(&1.tier), String.downcase(&1.name)})
        }
  end

  defp match_person?(person, q, tier) do
    (q == "" or String.contains?(String.downcase(person.name), q) or
       String.contains?(String.downcase(person.role || ""), q)) and
      (tier == "all" or to_string(person.tier) == tier)
  end

  defp tier_rank(tier), do: Enum.find_index(CharacterSheet.tiers(), &(&1 == tier)) || 9

  # Walk-ons collapse behind a count: they're the tier you scan past, and a campaign
  # with thirty of them shouldn't bury the two people you came for. Filtering to them
  # explicitly opens them, because then they're what you're looking at.
  defp split_walk_ons(people, tier) do
    if tier == "incidental" do
      {people, []}
    else
      Enum.split_with(people, &(&1.tier != :incidental))
    end
  end

  # ── Events ───────────────────────────────────────────────────────────────────

  # The only create action. A blank campaign, straight into its editor — no name is
  # required up front, and the campaign asks for the world and the people.
  def handle_event("new_campaign", _params, socket) do
    safe(socket, fn ->
      entry =
        Library.put(%{
          owner: socket.assigns.owner,
          kind: "campaign",
          payload: %{
            kind: :campaign,
            name: "",
            premise: "",
            character_ids: [],
            bible_id: nil,
            scenes: []
          }
        })

      {:noreply, push_navigate(socket, to: ~p"/campaigns/#{entry.id}")}
    end)
  end

  def handle_event("search", params, socket),
    do: {:noreply, assign(socket, query: params["q"] || "")}

  def handle_event("tier", %{"tier" => tier}, socket),
    do: {:noreply, assign(socket, tier: tier)}

  # Archive is filing — un-filing it is one button and no confirmation, because
  # nothing was ever at risk.
  def handle_event("unarchive", %{"id" => id}, socket) do
    safe(socket, fn ->
      Library.unarchive(id)
      {:noreply, socket |> put_flash(:info, "Back on the shelf.") |> load()}
    end)
  end

  def handle_event("restore", %{"id" => id}, socket) do
    safe(socket, fn ->
      Library.restore(id)
      {:noreply, socket |> put_flash(:info, "Put back.") |> load()}
    end)
  end

  # The one irreversible button in the screen, and the only one that confirms.
  def handle_event("purge", %{"id" => id}, socket) do
    safe(socket, fn ->
      Library.purge(id)
      {:noreply, socket |> put_flash(:info, "Gone for good.") |> load()}
    end)
  end

  def handle_event("forget_reading", %{"id" => id}, socket) do
    safe(socket, fn ->
      {:ok, _} = Library.soft_delete(id)
      {:noreply, load(socket)}
    end)
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title="Your stuff" subtitle={shelf_line(assigns)}>
        <:actions>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="new_campaign">
            New campaign
          </Kit.btn>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.tabs :if={not first_run?(assigns)}>
        <:tab patch={~p"/library?#{[tab: "campaigns"]}"} on={@tab == "campaigns"}>Campaigns</:tab>
        <:tab patch={~p"/library?#{[tab: "reading"]}"} on={@tab == "reading"}>Reading</:tab>
        <:tab patch={~p"/library?#{[tab: "worlds"]}"} on={@tab == "worlds"}>Worlds</:tab>
        <:tab patch={~p"/library?#{[tab: "people"]}"} on={@tab == "people"}>People</:tab>
        <:tab patch={~p"/library?#{[tab: "groups"]}"} on={@tab == "groups"}>Groups</:tab>
        <:tab patch={~p"/library?#{[tab: "shelves"]}"} on={@tab == "shelves"}>Archive</:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <%!-- First run: one button and no explanation of the three entity types,
              because you don't need to know about worlds and characters to start. --%>
        <Kit.sheet :if={first_run?(assigns)} class="m-4">
          <Kit.empty headline="Nothing here yet." class="py-10">
            A campaign is a world, some people, and the scenes you play out between them.
            Start one and it'll walk you through the rest.
            <:action>
              <Kit.btn kind={:primary} type="button" phx-click="new_campaign">New campaign</Kit.btn>
            </:action>
          </Kit.empty>
        </Kit.sheet>

        <.campaigns :if={@tab == "campaigns" and not first_run?(assigns)} {assigns} />
        <.reading :if={@tab == "reading"} {assigns} />
        <.worlds :if={@tab == "worlds"} {assigns} />
        <.people :if={@tab == "people"} {assigns} />
        <.groups :if={@tab == "groups"} {assigns} />
        <.shelves :if={@tab == "shelves"} {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── Campaigns ────────────────────────────────────────────────────────────────

  defp campaigns(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row :for={c <- @campaigns} class="px-4 py-3" style={row_tint(c)}>
        <div class="flex items-center justify-between gap-2 mb-1">
          <div class={["ttl text-[16px] min-w-0 truncate font-semibold", !c.named? && "dim"]}>
            <%= c.name %>
          </div>
          <Kit.pill colour={status_colour(c)} class="shrink-0"><%= badge(c) %></Kit.pill>
        </div>

        <div class="lbl dim mb-1.5"><%= meta_line(c) %></div>

        <p :if={c.premise} class={["text-[13px] leading-relaxed", c.status != :playing && "dim"]}>
          <%= c.premise %>
        </p>
        <p :if={is_nil(c.premise)} class="text-[13px] leading-relaxed dim">
          <%= no_premise(c) %>
        </p>

        <div :if={c.status == :playing} class="flex flex-wrap gap-1.5 mt-2">
          <.link navigate={~p"/campaigns/#{c.id}"} class="btn btn-pri btn-sm">Carry on</.link>
          <.link :if={c.pending > 0} navigate={~p"/arc/#{c.id}"} class="btn btn-gh btn-sm">
            <%= c.pending %> to review
          </.link>
        </div>

        <%!-- Published is a fact about the frozen copy, not a lever — the campaign's
              own settings own publication. --%>
        <div :if={c.published?} class="flex items-center gap-1.5 mt-2">
          <Kit.dot colour="var(--ok)" />
          <span class="text-[11px] dim"><%= copies_line(c) %></span>
        </div>
      </Kit.row>

      <Kit.empty :if={@campaigns == []} headline="No campaigns yet.">
        A campaign is where the worlds and the people get written. Start one and the rest
        follows.
        <:action>
          <Kit.btn kind={:primary} type="button" phx-click="new_campaign">New campaign</Kit.btn>
        </:action>
      </Kit.empty>

      <%!-- The front door the archive and the trash have never had. --%>
      <.link
        patch={~p"/library?#{[tab: "shelves"]}"}
        class="px-4 py-3 flex items-center justify-between gap-2"
      >
        <div class="flex items-center gap-3">
          <span class="text-[12px] dim"><%= length(@archived) %> archived</span>
          <span :if={@trashed != []} class="text-[12px]" style="color:var(--pencil)">
            <%= length(@trashed) %> in trash
          </span>
        </div>
        <span class="dim text-[14px]">›</span>
      </.link>
    </Kit.sheet>
    """
  end

  # ── Reading ──────────────────────────────────────────────────────────────────

  defp reading(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row :for={r <- @reading} class="px-4 py-3">
        <div class="flex items-center justify-between gap-2 mb-1">
          <div class={[
            "ttl text-[15px] min-w-0 truncate font-semibold",
            r.state == :gone && "dim"
          ]}>
            <%= reading_name(r) %>
          </div>
          <Kit.pill colour={reading_colour(r)} class="shrink-0"><%= reading_badge(r) %></Kit.pill>
        </div>

        <div :if={r.state != :gone and r.author} class="lbl dim mb-1.5"><%= reading_by(r) %></div>

        <p class={["text-[13px] leading-relaxed", r.state != :reading && "dim"]}>
          <%= reading_place(r) %>
        </p>

        <div :if={r.state == :reading} class="mt-2">
          <.link navigate={reading_path(r)} class="btn btn-pri btn-sm">
            Carry on reading
          </.link>
        </div>
      </Kit.row>

      <%!-- Its own shelf promises exactly one thing — you can get back to where you
            were — where filing it under Campaigns would promise play, fork and
            permanence, and deliver none of the three. --%>
      <Kit.empty :if={@reading == []} headline="You're not reading anything." class="py-9">
        People publish stories you can read from inside the head of someone in them.
        Anything you start shows up here with your place kept.
        <:action>
          <.link navigate={~p"/browse"} class="btn btn-gh btn-sm">Have a look</.link>
        </:action>
      </Kit.empty>
    </Kit.sheet>
    """
  end

  # ── Worlds ───────────────────────────────────────────────────────────────────

  defp worlds(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row :for={w <- @worlds} class="px-4 py-3">
        <div class="flex items-center justify-between gap-2 mb-1">
          <.link
            navigate={~p"/authoring/bible/#{w.id}"}
            class={["ttl text-[15px] min-w-0 truncate font-semibold", !w.named? && "dim"]}
          >
            <%= w.name %>
          </.link>
          <Kit.pill colour={visibility_colour(w.visibility)} class="shrink-0">
            <%= visibility_label(w.visibility) %>
          </Kit.pill>
        </div>
        <p :if={w.blurb} class="text-[12.5px] leading-relaxed dim mb-1.5"><%= w.blurb %></p>
        <p :if={is_nil(w.blurb)} class="text-[12.5px] leading-relaxed dim mb-1.5">
          Nothing written past the name.
        </p>
        <%!-- Past tense on purpose: attaching a world copies it (§2.5b), so this is a
              count of departures, not of dependants. Nothing here can break by editing. --%>
        <span class="text-[11px] dim"><%= started_line(w.started) %></span>
      </Kit.row>

      <Kit.empty :if={@worlds == []} headline="No worlds yet." class="py-9">
        You'll write one inside your first campaign. It'll show up here afterwards, and you
        can use it again in another campaign.
      </Kit.empty>
    </Kit.sheet>
    """
  end

  # ── People ───────────────────────────────────────────────────────────────────

  defp people(assigns) do
    assigns = assign(assigns, shown: shown_people(assigns))

    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-2.5">
        <form id="people-search" phx-change="search" phx-submit="search">
          <input
            type="text"
            name="q"
            value={@query}
            placeholder="Search people…"
            phx-debounce="200"
            class="field px-3 py-2 text-[13px] w-full"
          />
        </form>
        <div class="flex flex-wrap gap-1.5 mt-2">
          <.tier_pill tier="all" on={@tier == "all"} label="Everyone" />
          <.tier_pill
            :for={t <- CharacterSheet.tiers()}
            tier={to_string(t)}
            on={@tier == to_string(t)}
            label={CharacterSheet.tier_label(t)}
          />
        </div>
      </Kit.row>

      <%= for group <- @shown, {named, walk_ons} = split_walk_ons(group.people, @tier) do %>
        <Kit.row class="px-4 py-2" style="background:var(--b2)">
          <span class="lbl dim">
            <%= group.campaign || "Not in a campaign" %> · <%= length(group.people) %>
          </span>
        </Kit.row>
        <.person :for={p <- named} person={p} />
        <%!-- Walk-ons collapse: the tier you scan past shouldn't bury the two people
              you came for. Filtering to them opens them, because then they're the
              thing you're looking at. --%>
        <.link
          :if={walk_ons != []}
          patch={~p"/library?#{[tab: "people"]}"}
          phx-click="tier"
          phx-value-tier="incidental"
          class="px-4 py-2.5 row flex items-center justify-between gap-2"
        >
          <span class="text-[12px] dim"><%= walk_on_line(length(walk_ons)) %></span>
          <span class="dim text-[14px]">⌄</span>
        </.link>
      <% end %>

      <Kit.empty :if={@shown == [] and @query != ""} headline="Nobody by that name." class="py-8">
        Try clearing the tier filters — walk-ons are hidden more often than people expect.
      </Kit.empty>

      <Kit.empty :if={@shown == [] and @query == ""} headline="No people yet." class="py-9">
        People are written inside a campaign, next to the world they belong to.
      </Kit.empty>
    </Kit.sheet>
    """
  end

  attr(:person, :map, required: true)

  defp person(assigns) do
    ~H"""
    <Kit.row class="px-4 py-2.5 flex items-center gap-2.5">
      <span class="av" style={"background:#{@person.colour}"}></span>
      <div class="min-w-0 flex-1">
        <.link navigate={~p"/authoring/character/#{@person.id}"} class="text-[13px] font-semibold">
          <%= @person.name %>
        </.link>
        <div :if={@person.role} class="text-[11px] dim"><%= @person.role %></div>
      </div>
      <Kit.pill class="shrink-0"><%= short_tier(@person.tier) %></Kit.pill>
    </Kit.row>
    """
  end

  attr(:tier, :string, required: true)
  attr(:on, :boolean, required: true)
  attr(:label, :string, required: true)

  defp tier_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="tier"
      phx-value-tier={@tier}
      class={["pill", !@on && "dim"]}
      style={@on && "background:var(--b3)"}
      aria-pressed={to_string(@on)}
    >
      <%= @label %>
    </button>
    """
  end

  # ── Groups ───────────────────────────────────────────────────────────────────

  defp groups(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <%= for section <- @groups do %>
        <Kit.row class="px-4 py-2" style="background:var(--b2)">
          <span class="lbl dim"><%= section.campaign || "Not in a campaign" %></span>
        </Kit.row>
        <Kit.row :for={g <- section.groups} class="px-4 py-2.5 flex items-center gap-2.5">
          <span class="av" style={"background:#{group_colour(g)}"}></span>
          <div class="min-w-0 flex-1">
            <div class="text-[13px] font-semibold"><%= g.name %></div>
            <div class="text-[11px] dim"><%= group_line(g) %></div>
          </div>
        </Kit.row>
      <% end %>

      <div :if={@groups != []} class="px-4 py-6 text-center">
        <p class="text-[12.5px] leading-relaxed dim">
          Groups are written in a campaign, like characters. They seed new people and give
          secrets somewhere to point.
        </p>
      </div>

      <Kit.empty :if={@groups == []} headline="No groups yet." class="py-9">
        A group is written like a character and used as a starting point for others — a crew,
        a household, an order. It saves writing the same person five times.
      </Kit.empty>
    </Kit.sheet>
    """
  end

  # ── Archive & trash ──────────────────────────────────────────────────────────

  defp shelves(assigns) do
    ~H"""
    <div class="m-4 grid md:grid-cols-2 gap-4">
      <div>
        <Kit.sheet>
          <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="flex items-center gap-1.5">
              <span class="ttl text-[15px] font-semibold">Archived</span>
            </span>
            <Kit.pill class="shrink-0"><%= length(@archived) %></Kit.pill>
          </Kit.row>

          <Kit.row
            :for={e <- @archived}
            class="px-4 py-2.5 flex items-center gap-2.5 arch"
          >
            <span class="av" style={"background:#{entry_colour(e)}"}></span>
            <div class="min-w-0 flex-1">
              <div class="text-[13px] font-semibold"><%= entry_name(e) %></div>
              <div class="text-[11px] dim"><%= archived_line(e) %></div>
            </div>
            <Kit.btn size={:sm} type="button" phx-click="unarchive" phx-value-id={e.id} class="shrink-0">
              Restore
            </Kit.btn>
          </Kit.row>

          <Kit.empty :if={@archived == []} headline="Nothing archived." class="py-7">
            Anything you file away goes here and stays here.
          </Kit.empty>
        </Kit.sheet>
        <p class="text-[12px] mt-2 dim">
          Nothing here is going anywhere. Archive is filing, not deleting.
        </p>
      </div>

      <div>
        <Kit.sheet>
          <Kit.row class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="flex items-center gap-1.5">
              <span class="ttl text-[15px] font-semibold">Trash</span>
            </span>
            <Kit.pill colour={@trashed != [] && "var(--pencil)"} class="shrink-0">
              <%= length(@trashed) %>
            </Kit.pill>
          </Kit.row>

          <Kit.row :for={e <- @trashed} class="px-4 py-2.5 arch">
            <div class="flex items-center gap-2.5">
              <span class="av" style="background:var(--b3)"></span>
              <div class="min-w-0 flex-1">
                <div class="text-[13px] font-semibold"><%= entry_name(e) %></div>
                <%!-- The countdown is the whole point: the one place the recovery
                      window is a number rather than a claim (§2.13). --%>
                <div class="text-[11px]" style="color:var(--pencil)"><%= countdown(e) %></div>
              </div>
            </div>
            <div class="flex gap-1.5 mt-2">
              <Kit.btn size={:sm} type="button" phx-click="restore" phx-value-id={e.id}>
                Put it back
              </Kit.btn>
              <Kit.btn
                kind={:pen}
                size={:sm}
                type="button"
                phx-click="purge"
                phx-value-id={e.id}
                data-confirm="Delete this for good? There's no getting it back."
              >
                Delete now
              </Kit.btn>
            </div>
          </Kit.row>

          <Kit.empty :if={@trashed == []} headline="Empty." class="py-7">
            Deleted things wait <%= Library.retention_days() %> days before they're really gone.
          </Kit.empty>
        </Kit.sheet>
        <p class="text-[12px] mt-2 dim">
          The countdown is the whole point — it's the only place the recovery window is a
          number rather than a claim.
        </p>
      </div>
    </div>
    """
  end

  # First run is *nothing at all* — including nothing archived and nothing in the
  # trash. Keying it on the live entries alone would hide the tabs the moment someone
  # filed their only campaign, which is precisely the "the archive is unreachable"
  # problem this screen exists to end.
  defp first_run?(assigns) do
    assigns.entries == [] and assigns.reading == [] and assigns.archived == [] and
      assigns.trashed == []
  end

  # ── Copy ─────────────────────────────────────────────────────────────────────

  defp shelf_line(assigns) do
    # Only what's actually open — a finished or unpublished story isn't something
    # you're partway through, and counting it would overstate the shelf.
    open = Enum.count(assigns.reading, &(&1.state == :reading))

    [
      count_label(length(assigns.campaigns), "campaign", "campaigns"),
      open > 0 && count_label(open, "story", "stories") <> " open"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(n, _one, many), do: "#{n} #{many}"

  defp meta_line(c) do
    [
      c.world,
      count_label(c.people, "person", "people"),
      count_label(c.scenes, "scene", "scenes")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
    |> case do
      "" -> "No world yet"
      line -> if c.world, do: line, else: "No world yet · " <> line
    end
  end

  defp badge(%{published?: true}), do: "Published"
  defp badge(c), do: c.status_label

  defp status_colour(%{published?: true}), do: "var(--ok)"
  defp status_colour(%{status: :playing}), do: "var(--lamp)"
  defp status_colour(_), do: nil

  # The open campaign is the one you came back for, so it's the one the eye lands on.
  defp row_tint(%{status: :playing}),
    do: "background:color-mix(in srgb,var(--lamp) 7%,transparent)"

  defp row_tint(_), do: nil

  defp no_premise(%{status: :unstarted}), do: "Made and never opened again."
  defp no_premise(%{status: :finished}), do: "Finished, with nothing written about it."
  defp no_premise(_), do: "Nothing written down about it yet."

  defp copies_line(c) do
    case c.copies do
      0 -> "Published · nobody has taken a copy yet"
      n -> "Published · " <> count_label(n, "person has", "people have") <> " taken a copy"
    end
  end

  defp started_line(0), do: "Never used"
  defp started_line(1), do: "1 campaign started from this"
  defp started_line(n), do: "#{n} campaigns started from this"

  defp walk_on_line(1), do: "1 walk-on"
  defp walk_on_line(n), do: "#{n} walk-ons"

  defp short_tier(:main), do: "Main"
  defp short_tier(:recurring), do: "Recurring"
  defp short_tier(_), do: "Walk-on"

  defp group_line(%{members: m, secrets: 0}), do: count_label(m, "member", "members")

  defp group_line(%{members: m, secrets: s}),
    do: count_label(m, "member", "members") <> " · " <> count_label(s, "secret", "secrets")

  defp group_colour(%{secrets: s, colour: colour}),
    do: if(s > 0, do: "var(--secret)", else: colour)

  defp visibility_label("public"), do: "Public"
  defp visibility_label("unlisted"), do: "Unlisted"
  defp visibility_label(_), do: "Private"

  defp visibility_colour("public"), do: "var(--ok)"
  defp visibility_colour("unlisted"), do: "var(--lamp)"
  defp visibility_colour(_), do: nil

  defp archived_line(entry) do
    [kind_label(entry.kind), month_of(entry.archived_at)]
    |> Enum.filter(& &1)
    |> Enum.join(" · archived in ")
  end

  defp kind_label("world_bible"), do: "World"
  defp kind_label("character"), do: "Character"
  defp kind_label("campaign"), do: "Campaign"
  defp kind_label(kind), do: String.capitalize(to_string(kind))

  defp month_of(nil), do: nil
  defp month_of(at), do: Calendar.strftime(at, "%B")

  defp countdown(entry) do
    case Library.days_until_purge(entry) do
      nil -> "Waiting to be purged"
      0 -> "Gone for good today"
      1 -> "Gone for good tomorrow"
      n -> "Gone for good in #{n} days"
    end
  end

  # ── Reading copy ─────────────────────────────────────────────────────────────

  # A published story is named by its world, not by the snapshot — `entry_name/1` is
  # for the owner's own library entries and would render every story here as untitled.
  defp reading_name(%{source: nil}), do: "A story you were reading"
  defp reading_name(%{source: source}), do: Session.title(Library.payload(source))

  defp reading_badge(%{state: :gone}), do: "Gone"
  defp reading_badge(%{state: :finished}), do: "Finished"
  defp reading_badge(row), do: row.perspective

  defp reading_colour(%{state: :gone}), do: nil
  defp reading_colour(%{state: :finished}), do: "var(--lamp)"
  defp reading_colour(_), do: "var(--v2)"

  defp reading_by(%{author: nil}), do: ""
  defp reading_by(%{author: author}), do: "By " <> author

  # Unpublishing keeps the bookmark, so this row still knows where they were — it just
  # has nowhere to send them until it comes back.
  defp reading_place(%{state: :gone}),
    do: "The author unpublished this. Your place is kept in case it comes back."

  defp reading_place(%{state: :finished} = row) do
    case row.bookmark.finished_at do
      nil -> "Finished it."
      at -> "Finished it in " <> Calendar.strftime(at, "%B") <> "."
    end
  end

  defp reading_place(row) do
    case Reading.position(row.bookmark, row.source) do
      {i, n} -> "Scene #{i} of #{n}."
      nil -> "Partway through."
    end
  end

  # Straight back to the scene, in the head they were in. All three parts of the
  # bookmark (§3.1e) ride in the URL, so the link is the whole promise the shelf makes
  # — landing on a front page and asking them to find their place again would be a
  # slower way of keeping nothing.
  #
  # `browse` re-checks the grant, so a perspective the author has since withdrawn falls
  # back rather than opening: the link carries an intent, never an authorization.
  defp reading_path(%{source: %{id: id}, bookmark: bookmark}) do
    params =
      [story: id] ++
        param(:scene, bookmark.scene_id) ++
        param(:as, bookmark.perspective)

    ~p"/browse?#{params}"
  end

  defp reading_path(_row), do: ~p"/browse"

  defp param(_key, nil), do: []
  defp param(key, value), do: [{key, to_string(value)}]

  # ── Shared ───────────────────────────────────────────────────────────────────

  defp entry_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> untitled(entry.kind)
    end
  end

  defp untitled("world_bible"), do: "Untitled world"
  defp untitled("campaign"), do: "Untitled campaign"
  defp untitled("character"), do: "Someone unnamed"
  defp untitled(_), do: "Untitled"

  defp entry_colour(entry) do
    case Library.payload(entry) do
      %{hue: _} = payload -> Voice.of_sheet(payload)
      _ -> "var(--b3)"
    end
  end

  defp named?(%{name: n}) when is_binary(n) and n != "", do: true
  defp named?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
