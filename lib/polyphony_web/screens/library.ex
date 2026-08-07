defmodule PolyphonyWeb.Screens.Library do
  @moduledoc """
  The library, as markup — your shelf.

  Everything you have written, grouped by kind, with the walk-ons a story invented held
  apart from the people you sat down and wrote. That split is the screen's one real
  idea: a cast list that mixes them reads as clutter, and deleting the clutter is how
  somebody loses a character they meant to keep.

  Deleted things wait out a retention window before they are really gone, so the trash
  is a state of the shelf rather than a different screen.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Library
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyWeb.{Kit, Layouts}

  # "" in the app; a distinct prefix per storybook variation, which all render together.
  defp eid("", name), do: name
  defp eid(nil, name), do: name
  defp eid(prefix, name), do: "#{prefix}-#{name}"

  attr(:id, :string, default: "", doc: "prefix for every element id — see eid/2")

  attr(:current_user, :map, default: nil)

  attr(:entries, :list,
    default: [],
    doc:
      "every entry — `first_run?/1` asks whether the shelf is empty, which the derived lists cannot answer on their own"
  )

  attr(:tab, :string, default: "campaigns")
  attr(:menu_for, :any, default: nil, doc: "which row's overflow menu is open")
  attr(:query, :string, default: "")
  attr(:tier, :string, default: "all", doc: "cast-tier filter on the People tab")
  attr(:campaigns, :list, default: [])
  attr(:worlds, :list, default: [])
  attr(:people, :any, default: %{}, doc: "written people and walk-ons, held apart")
  attr(:groups, :list, default: [])
  attr(:reading, :list, default: [])

  attr(:archived, :list,
    default: [],
    doc: "filed away — recoverable, one button, no confirmation"
  )

  attr(:trashed, :list, default: [], doc: "deleted, waiting out the retention window")

  def screen(assigns) do
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

      <.row_menu_overlay :if={@menu_for && menu_row(assigns)} c={menu_row(assigns)} />
    </Kit.frame>
    """
  end

  # Filing and throwing away, which this screen is the front door for (see the
  # moduledoc) and which the rows themselves had no way to reach: `Library.archive/2`
  # had no caller anywhere, so the Archive shelf could only ever be empty.
  #
  # **An overlay, not an in-flow panel.** It was in the flow because the kit's `.sheet`
  # is `overflow:hidden`, which clips an absolutely-positioned dropdown — but the cost
  # of opening in the flow is that every row below jumps down the page, so the campaign
  # you were reading moves out from under you at the moment you touch its menu. The kit
  # already answers this (`Kit.overlay`, §"opened *from* a control rather than being
  # part of the page"): it is `position:fixed`, so the sheet's clipping never applies,
  # and it costs the page no layout at all.
  attr(:c, :map, required: true)

  defp row_menu(assigns) do
    ~H"""
    <button
      type="button"
      class="pill"
      aria-label={"Change #{@c.name}"}
      phx-click="row_menu"
      phx-value-id={@c.id}
    >
      ⋯
    </button>
    """
  end

  # The open one. Rendered once at the screen level rather than per row, so the markup
  # doesn't exist until something is open.
  attr(:c, :map, required: true)

  defp row_menu_overlay(assigns) do
    {to, verb} = row_open(assigns.c)
    assigns = assign(assigns, to: to, verb: verb)

    ~H"""
    <Kit.overlay label={"Change #{@c.name}"} on_close="close_row_menu">
      <div class="px-4 py-3 row flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold min-w-0 truncate"><%= @c.name %></span>
        <Kit.btn size={:sm} type="button" phx-click="close_row_menu">✕</Kit.btn>
      </div>
      <.link navigate={@to} class="row block px-4 py-3 text-[13px]">
        <%= @verb %>
      </.link>
      <button
        type="button"
        class="row w-full px-4 py-3 text-[13px] text-left"
        phx-click="archive"
        phx-value-id={@c.id}
      >
        Archive
        <span class="block text-[11px] dim">Out of the way, and nothing is at risk.</span>
      </button>
      <%!-- Trash is on a clock rather than immediate, so this needs no confirmation —
            the irreversible button lives on the trash shelf, where it says so. --%>
      <button
        type="button"
        class="w-full px-4 py-3 text-[13px] text-left"
        style="color:var(--pencil)"
        phx-click="trash"
        phx-value-id={@c.id}
      >
        Move to trash
        <span class="block text-[11px] dim">
          Recoverable until it expires. <%= row_note(@c) %>
        </span>
      </button>
    </Kit.overlay>
    """
  end

  # The open row, whatever kind it is. `menu_for` is an id, and an id is unique across
  # the library, so the kind is resolved here rather than carried through the click —
  # one less thing a `phx-value-*` can be wrong about.
  defp menu_row(assigns) do
    Enum.find_value(
      [
        {"campaign", assigns.campaigns},
        {"world_bible", assigns.worlds},
        {"character", Enum.flat_map(assigns.people, & &1.people)}
      ],
      fn {kind, rows} ->
        case Enum.find(rows, &(to_string(&1.id) == assigns.menu_for)) do
          nil -> nil
          row -> Map.put(row, :kind, kind)
        end
      end
    )
  end

  # Where the row's own editor is. The campaign hub is an "Open"; a world and a
  # character are things you edit, and saying so is the difference between a menu that
  # reads as navigation and one that reads as a filing cabinet.
  defp row_open(%{kind: "campaign", id: id}), do: {~p"/campaigns/#{id}", "Open"}
  defp row_open(%{kind: "world_bible", id: id}), do: {~p"/authoring/bible/#{id}", "Edit"}
  defp row_open(%{kind: "character", id: id}), do: {~p"/authoring/character/#{id}", "Edit"}

  # What goes with it when it goes. Said out loud rather than left to be discovered:
  # a world is a template and campaigns hold their own copies, so nothing that is
  # being played breaks — but a character on a roster simply stops being there until
  # they're restored, and that is worth knowing before you press it.
  defp row_note(%{kind: "world_bible"}),
    do: "Campaigns started from it keep their own copy — nothing being played breaks."

  defp row_note(%{kind: "character"}),
    do: "They leave any cast they're in until you put them back."

  defp row_note(_), do: "The world and the cast go with it."

  # ── Campaigns ────────────────────────────────────────────────────────────────

  defp campaigns(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row :for={c <- @campaigns} class="px-4 py-3" style={row_tint(c)}>
        <div class="flex items-center justify-between gap-2 mb-1">
          <%!-- The title is the way in, whatever state the campaign is in. It used to
                be that the only link on the row was "Carry on", which is `:playing`
                only — so a campaign you had just made, or had finished, could not be
                opened from the library at all. --%>
          <.link
            navigate={~p"/campaigns/#{c.id}"}
            class={["ttl text-[16px] min-w-0 truncate font-semibold", !c.named? && "dim"]}
          >
            <%= c.name %>
          </.link>
          <div class="flex items-center gap-1.5 shrink-0">
            <Kit.pill colour={status_colour(c)}><%= badge(c) %></Kit.pill>
            <.row_menu c={c} />
          </div>
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
            <%= r.name %>
          </div>
          <Kit.pill colour={reading_colour(r)} class="shrink-0"><%= reading_badge(r) %></Kit.pill>
        </div>

        <div :if={r.state != :gone and r.author} class="lbl dim mb-1.5"><%= reading_by(r) %></div>

        <p class={["text-[13px] leading-relaxed", r.state != :reading && "dim"]}>
          <%= r.place %>
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
          <div class="flex items-center gap-1.5 shrink-0">
            <Kit.pill colour={visibility_colour(w.visibility)}>
              <%= visibility_label(w.visibility) %>
            </Kit.pill>
            <.row_menu c={w} />
          </div>
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
        <form id={eid(@id, "people-search")} phx-change="search" phx-submit="search">
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
              thing you're looking at.

              **A button, not a link.** It was a `patch` to the URL it was already on,
              carrying a `phx-click` to do the actual work — and LiveView's nav handler
              calls `stopImmediatePropagation()` on a `data-phx-link` click, so the
              ordinary click binding never sees it. The only route left is the
              `phx-click` lookup at the end of that handler, which sits *after* an early
              `return` when the patch href matches the pending one. Clicking the row did
              nothing. The tier filter is socket state and the URL never changed, so the
              link was buying nothing to begin with — and the tier pills above are plain
              buttons doing exactly this. --%>
        <button
          :if={walk_ons != []}
          type="button"
          phx-click="tier"
          phx-value-tier="incidental"
          class="w-full px-4 py-2.5 row flex items-center justify-between gap-2 text-left"
        >
          <span class="text-[12px] dim"><%= walk_on_line(length(walk_ons)) %></span>
          <span class="dim text-[14px]">⌄</span>
        </button>
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
      <div class="flex items-center gap-1.5 shrink-0">
        <Kit.pill><%= short_tier(@person.tier) %></Kit.pill>
        <.row_menu c={@person} />
      </div>
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
            <span class="av" style={"background:#{e.colour}"}></span>
            <div class="min-w-0 flex-1">
              <div class="text-[13px] font-semibold"><%= e.name %></div>
              <div class="text-[11px] dim"><%= e.line %></div>
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
                <div class="text-[13px] font-semibold"><%= e.name %></div>
                <%!-- The countdown is the whole point: the one place the recovery
                      window is a number rather than a claim (§2.13). --%>
                <div class="text-[11px]" style="color:var(--pencil)"><%= e.line %></div>
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

  defp reading_badge(%{state: :gone}), do: "Gone"
  defp reading_badge(%{state: :finished}), do: "Finished"
  defp reading_badge(row), do: row.perspective

  defp reading_colour(%{state: :gone}), do: nil
  defp reading_colour(%{state: :finished}), do: "var(--lamp)"
  defp reading_colour(_), do: "var(--v2)"

  defp reading_by(%{author: nil}), do: ""
  defp reading_by(%{author: author}), do: "By " <> author

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

  def named?(%{name: n}) when is_binary(n) and n != "", do: true
  def named?(_), do: false

  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil

  def blank_to_nil(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_), do: nil

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
  # Every destructive button on this screen goes through here, and the check is the
  # reason it exists. The lists are scoped to the owner, so the buttons only ever appear
  # on your own things — but the id comes back in the event, and `Library.purge/1` does
  # not ask whose entry it is. Archiving, trashing and purging a stranger's campaign was
  # a matter of knowing a small integer.
  #
  # Archived and trashed entries are out of the default lists, so the lookup has to see
  # them or restoring your own work would refuse itself.

  defp tier_rank(tier), do: Enum.find_index(CharacterSheet.tiers(), &(&1 == tier)) || 9

  defp match_person?(person, q, tier) do
    (q == "" or String.contains?(String.downcase(person.name), q) or
       String.contains?(String.downcase(person.role || ""), q)) and
      (tier == "all" or to_string(person.tier) == tier)
  end
end
