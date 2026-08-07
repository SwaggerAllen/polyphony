defmodule PolyphonyWeb.Screens.ArcReview do
  @moduledoc """
  Arc review, as markup.

  The gate between scenes: what a scene decided about the people in it, proposed rather
  than applied. Accepting is a deliberate act and refusing one is how you write the
  person who didn't go along with it — the review is a feature of the fiction, not a
  safety rail.

  A group change fans out into one proposal against the template and one per current
  member, and the screen **collapses that fan-out into a single card** — a group of
  twelve would otherwise flood the queue from a change nobody made twelve times.
  """
  use PolyphonyWeb, :html

  alias Polyphony.Authoring.ArcEntry
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  attr(:campaign_id, :string, required: true)
  attr(:campaign_name, :string, default: "")
  attr(:cast, :any, required: true, doc: "%Cast{} — names are display, ids are the key")
  attr(:groups, :list, default: [])
  attr(:world, :list, default: [], doc: "world-arc proposals; global facts reach everywhere")
  attr(:per_character, :any, default: %{}, doc: "character_id => their pending proposals")
  attr(:tab, :any, default: nil)
  attr(:drawer, :any, default: nil)
  attr(:editing, :any, default: nil, doc: "the proposal being corrected before it is taken")
  attr(:current_user, :map, default: nil)

  def screen(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header
        title="What play made of them"
        eyebrow={@campaign_name}
        subtitle={pending_line(assigns)}
        back={~p"/campaigns/#{@campaign_id}"}
        back_label="Back to the campaign"
      >
        <:actions>
          <Kit.info label="arc review" phx-click="drawer" />
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- A tab per subject: reviewing is per-person work, and a flat list makes you
            re-orient on every card. A tab with nothing pending still shows, at zero,
            so its absence never reads as "not extracted yet". --%>
      <Kit.tabs :if={@cast != []}>
        <:tab
          :for={c <- @cast}
          patch={~p"/arc/#{@campaign_id}?#{[tab: c.id]}"}
          on={@tab == c.id}
        >
          <%= c.name %> <span class="dim"><%= length(@per_character[c.id] || []) %></span>
        </:tab>
        <:tab patch={~p"/arc/#{@campaign_id}?#{[tab: "world"]}"} on={@tab == "world"}>
          <%= @campaign_name %> <span class="dim"><%= length(@world) %></span>
        </:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <.drawer :if={@drawer} />

        <Kit.sheet :if={visible(assigns) != []} class="m-4">
          <.proposal
            :for={e <- visible(assigns)}
            entry={e}
            was={was(e, subject_sheet(assigns))}
            editing={@editing}
            world={@tab == "world"}
          />

          <div class="px-4 py-3 flex items-center justify-between gap-2" style="background:var(--b2)">
            <span class="text-[12.5px] dim"><%= subject_name(assigns) %>, all at once</span>
            <Kit.btn
              size={:sm}
              type="button"
              phx-click="accept_all"
              phx-value-subject={subject_id(assigns)}
            >
              Accept all <%= length(visible(assigns)) %>
            </Kit.btn>
          </div>
        </Kit.sheet>

        <Kit.empty
          :if={visible(assigns) == [] and @groups == []}
          headline={empty_headline(assigns)}
          class="m-4"
        >
          When a scene closes, whatever it changed about your people and your world turns
          up here first.
        </Kit.empty>

        <.group_card :for={g <- @groups} group={g} cast={@cast} editing={@editing} />
      </div>
    </Kit.frame>
    """
  end

  # ── Components ────────────────────────────────────────────────────────────────

  # One proposal: what it would change, what it changes it *from*, and what in the
  # scene caused it. The last part is what the design says makes accepting quick.
  attr(:entry, :map, required: true)
  attr(:was, :string, default: nil)
  attr(:editing, :any, default: nil)
  attr(:world, :boolean, default: false)

  defp proposal(assigns) do
    ~H"""
    <div class="row px-4 py-3">
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="lbl dim"><%= heading(@entry) %></span>
        <Kit.pill :if={@world and @entry.scope == "local"} colour="var(--lamp)">
          Known here first
        </Kit.pill>
      </div>

      <%!-- What it changes *from*, struck through. Only a revision has one — a
            discovery adds rather than supersedes, and struck-through text there would
            be a lie about what's happening. --%>
      <p :if={@was} class="text-[12.5px] leading-relaxed dim was mb-2"><%= @was %></p>

      <form :if={@editing == @entry.id} id={"edit-#{@entry.id}"} phx-submit="save_edit">
        <input type="hidden" name="entry_id" value={@entry.id} />
        <label for={"stmt-#{@entry.id}"} class="sr-only">The change</label>
        <textarea
          id={"stmt-#{@entry.id}"}
          name="statement"
          rows="3"
          class="field px-3 py-2.5 text-[13.5px] leading-relaxed w-full"
        ><%= @entry.statement %></textarea>
        <div :if={@world} class="mt-2">
          <label for={"scope-#{@entry.id}"} class="lbl dim">How far it reaches</label>
          <select
            id={"scope-#{@entry.id}"}
            name="scope"
            class="field px-3 py-2 text-[13px] w-full mt-1.5"
          >
            <option value="global" selected={@entry.scope != "local"}>Everywhere</option>
            <option value="local" selected={@entry.scope == "local"}>Where it happened</option>
          </select>
        </div>
        <div class="flex gap-1.5 mt-2">
          <Kit.btn kind={:primary} size={:sm} type="submit">Save it</Kit.btn>
          <Kit.btn size={:sm} type="button" phx-click="cancel_edit">Cancel</Kit.btn>
        </div>
      </form>

      <div :if={@editing != @entry.id}>
        <%!-- On a release the line that gave leads and the after-state follows, because
              *what broke* is the decision and *what she's like now* is its consequence. --%>
        <Kit.marked mark={:prop} class="mb-2.5">
          <p :if={present?(@entry.released_topic)} class="text-[14px] leading-relaxed mb-1">
            <%= @entry.released_topic %> — it broke.
          </p>
          <p class={[
            "leading-relaxed",
            if(present?(@entry.released_topic), do: "text-[12.5px] dim", else: "text-[14px]")
          ]}>
            <%= @entry.statement %>
          </p>
        </Kit.marked>

        <div :if={present?(@entry.reason)}>
          <div class="lbl dim mb-1">Because</div>
          <p class="text-[12.5px] leading-relaxed dim mb-2.5"><%= @entry.reason %></p>
        </div>

        <%!-- A world fact also has to say who comes to know it — the audience picker
              doing the same job it does on a secret. --%>
        <div
          :if={@world}
          class="flex items-center justify-between gap-2 mb-2.5 pt-2.5"
          style="border-top:1px solid var(--rule)"
        >
          <span class="text-[12.5px] dim">Who knows</span>
          <Kit.pill colour={if(@entry.concealed, do: "var(--secret)", else: "var(--lamp)")}>
            <%= if @entry.concealed, do: "Whoever was there", else: "Everyone" %>
          </Kit.pill>
        </div>

        <div class="flex flex-wrap gap-1.5">
          <Kit.btn
            kind={:primary}
            size={:sm}
            type="button"
            phx-click="accept"
            phx-value-id={@entry.id}
          >
            True
          </Kit.btn>
          <Kit.btn size={:sm} type="button" phx-click="edit" phx-value-id={@entry.id}>Edit</Kit.btn>
          <Kit.btn size={:sm} type="button" phx-click="reject" phx-value-id={@entry.id}>
            <%= if @entry.kind == "release", do: "Not yet", else: "No" %>
          </Kit.btn>
        </div>
      </div>
    </div>
    """
  end

  # A group's fan-out, collapsed. One card, one fast path, expandable when it matters
  # — a group of twelve would otherwise flood the queue.
  attr(:group, :map, required: true)
  attr(:cast, :list, required: true)
  attr(:editing, :any, default: nil)

  defp group_card(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-3" style="background:var(--b2)">
        <div class="flex items-center gap-2.5">
          <span class="av" style="background:var(--secret)"></span>
          <div class="min-w-0 flex-1">
            <div class="ttl text-[15px] font-semibold"><%= @group.name %></div>
            <div class="lbl dim"><%= fan_out_line(@group.counts) %></div>
          </div>
        </div>
      </Kit.row>

      <.proposal :for={e <- @group.pending.group} entry={e} editing={@editing} />

      <%!-- Expanded, per member. This is where dissent lives: accept the group's
            change, refuse one person's, and you've written the one who didn't go along
            with it — a story beat you'd otherwise have to author by hand. --%>
      <details :if={@group.pending.members != []}>
        <summary class="row px-4 py-2.5 flex items-center justify-between gap-2 cursor-pointer list-none">
          <span class="text-[12.5px] dim">Everyone in it changed too</span>
          <span class="dim text-[14px]">⌄</span>
        </summary>
        <div :for={{member_id, rows} <- @group.pending.members}>
          <Kit.row class="px-4 py-2 flex items-center gap-2.5" style="background:var(--b2)">
            <span class="av" style={"background:#{member_colour(@cast, member_id)}"}></span>
            <span class="text-[13px] font-semibold flex-1 min-w-0 truncate">
              <%= member_name(@cast, member_id) %>
            </span>
          </Kit.row>
          <.proposal :for={e <- rows} entry={e} editing={@editing} />
        </div>
      </details>

      <div class="px-4 py-3" style="background:var(--b2)">
        <Kit.btn
          kind={:primary}
          type="button"
          class="w-full justify-center"
          phx-click="accept_group"
          phx-value-id={@group.id}
        >
          True for all <%= @group.counts.group + @group.counts.members %>
        </Kit.btn>
      </div>
    </Kit.sheet>
    """
  end

  defp drawer(assigns) do
    ~H"""
    <Kit.info_drawer title="About this" on_close="drawer">
      <:intro>
        A scene closed and the engine worked out what it changed. Nothing here is true
        until you say so, and nothing is lost if you leave it.
      </:intro>
      <:part colour="var(--lamp)" name="Why it holds up a new scene">
        Generation works from the sheet. An unreviewed change is a gap between who
        someone is on paper and who they've become — let it run and the Director is
        writing someone who stopped existing two scenes ago. Only the cast you're about
        to use has to be current.
      </:part>
      <:part colour="var(--ok)" name="Accept all is the fast path">
        It's meant to be used. The gate exists to keep things consistent, not to make
        you read carefully — one tap still leaves you with sheets that match your story.
      </:part>
    </Kit.info_drawer>
    """
  end

  # ── Render helpers ────────────────────────────────────────────────────────────

  defp visible(%{tab: "world", world: world}), do: world
  defp visible(%{tab: tab, per_character: per}), do: Map.get(per, tab, [])

  defp subject_id(%{tab: "world", campaign_id: id}), do: id
  defp subject_id(%{tab: tab}), do: tab

  defp subject_sheet(%{tab: "world"}), do: nil

  defp subject_sheet(%{tab: tab, cast: cast}) do
    case Enum.find(cast, &(&1.id == tab)) do
      %{sheet: sheet} -> sheet
      _ -> nil
    end
  end

  defp subject_name(%{tab: "world", campaign_name: name}), do: name

  defp subject_name(%{tab: tab, cast: cast}) do
    case Enum.find(cast, &(&1.id == tab)) do
      %{name: name} -> name
      _ -> "This subject"
    end
  end

  defp pending_line(assigns) do
    total =
      length(assigns.world) +
        (assigns.per_character |> Map.values() |> Enum.map(&length/1) |> Enum.sum())

    case total do
      0 -> "Nothing waiting"
      1 -> "1 change waiting"
      n -> "#{n} changes waiting"
    end
  end

  defp empty_headline(%{tab: "world"}), do: "The world is as you left it."
  defp empty_headline(assigns), do: "#{subject_name(assigns)} is up to date."

  defp fan_out_line(%{group: g, members: m}),
    do: "#{change_word(g)} to the group · #{m} to its people"

  defp change_word(1), do: "1 change"
  defp change_word(n), do: "#{n} changes"

  defp heading(entry) do
    ArcEntry.label(%ArcEntry{
      kind: safe_kind(entry.kind),
      sheet_field: entry.sheet_field,
      statement: entry.statement
    })
  end

  defp safe_kind("release"), do: :release
  defp safe_kind("revision"), do: :revision
  defp safe_kind(_), do: :discovery

  # What a revision replaces, read off the sheet it would replace it on.
  defp was(%{kind: "revision", sheet_field: field}, sheet)
       when is_binary(field) and field != "" and is_map(sheet) do
    case Map.get(sheet, safe_field(field)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp was(_entry, _sheet), do: nil

  defp safe_field(field), do: String.to_existing_atom(field)

  defp member_name(cast, id) do
    case Enum.find(cast, &(&1.id == to_string(id))) do
      %{name: name} -> name
      _ -> "Someone"
    end
  end

  defp member_colour(cast, id) do
    case Enum.find(cast, &(&1.id == to_string(id))) do
      %{sheet: sheet} -> Voice.of_sheet(sheet)
      _ -> Voice.neutral()
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
