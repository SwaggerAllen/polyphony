defmodule PolyphonyWeb.ArcReviewLive do
  @moduledoc """
  Arc review, ported from `ux/polyphony-arc.html` — *what play made of them*.

  A scene closes and the engine proposes what changed, about the people in it and
  about the world. **Nothing is true until you say so**, and nothing is lost if you
  don't: a proposal left alone stays a proposal.

  ## Every proposal says what, from what, and why

  The design's argument for the *Because* line is that it is what makes accepting
  quick — you can check the reasoning without going back and rereading the scene. A
  revision also shows what it changes *from*, struck through, because a replacement
  you can't compare is one you have to take on trust.

  ## Tabs are per subject, and the world is one of them

  Wren, Ilias, Corrigan, Saltmarch — a scene's proposals sorted by who they're about,
  because reviewing is per-person work and a flat list makes you re-orient on every
  card. A tab with nothing pending still shows, at zero, so its absence never reads as
  *not extracted yet*.

  ## Accept-all is the intended fast path, and the only one

  The gate exists to keep state consistent, not to force careful reading. Someone in a
  hurry taps once and still gets sheets that match their story; there is no second
  escape hatch, because one tap is already as cheap as an escape hatch gets.

  ## Groups collapse

  A group of twelve would flood the queue, so a fan-out is one card with one fast
  path, expandable when it matters (`Polyphony.Authoring.GroupArc`). The expansion is
  where dissent lives: accept the group's change, refuse one member's, and you have
  written the person who didn't go along with it.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Groups, Library, Owner, Repo}
  alias Polyphony.Authoring.ArcEntry
  alias Polyphony.ReadModels.ArcEntry, as: ArcEntryRepo
  alias PolyphonyWeb.{Kit, Layouts, Voice}

  def mount(%{"campaign_id" => id}, _session, socket) do
    entry = Library.get(id)
    campaign = entry && Library.payload(entry)

    {:ok,
     socket
     |> assign(
       page_title: "Review",
       campaign_id: id,
       campaign_name: campaign_name(campaign),
       cast: cast(campaign),
       editing: nil,
       drawer: false
     )
     |> load()}
  end

  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, tab: params["tab"] || default_tab(socket))}

  # Character arc is keyed by the character's **library id** — the same identity the
  # cast enters a scene under and extraction files against (§5.2). Names ride along
  # only to label the proposals; before the mint flip this had to resolve ids to
  # names to find anything, and that dance is what a rename used to break.
  defp cast(nil), do: []

  defp cast(campaign) do
    (campaign[:character_ids] || [])
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Library.get(id) do
        nil ->
          []

        entry ->
          sheet = Library.payload(entry) || %{}
          [%{id: to_string(entry.id), name: Map.get(sheet, :name) || to_string(id), sheet: sheet}]
      end
    end)
  end

  defp campaign_name(nil), do: "Campaign"
  defp campaign_name(campaign), do: campaign[:name] || "Campaign"

  defp load(socket) do
    per_character =
      Map.new(socket.assigns.cast, &{&1.id, ArcEntryRepo.list_proposed(Repo, &1.id)})

    world = ArcEntryRepo.list_proposed_world(Repo, socket.assigns.campaign_id)

    groups =
      for g <- Groups.list(Owner.of(socket.assigns.current_user)),
          pending = Polyphony.Authoring.GroupArc.pending(g.id),
          pending.group != [] or pending.members != [] do
        %{
          id: to_string(g.id),
          name: group_name(g),
          counts: Polyphony.Authoring.GroupArc.counts(g.id),
          pending: pending
        }
      end

    assign(socket, per_character: per_character, world: world, groups: groups)
  end

  defp group_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "A group"
    end
  end

  # Open on the first subject that actually has something waiting — the reason you
  # came here — rather than on whoever happens to be first in the cast.
  defp default_tab(socket) do
    case Enum.find(socket.assigns.cast, &(socket.assigns.per_character[&1.id] != [])) do
      %{id: id} ->
        id

      _ ->
        cond do
          socket.assigns.world != [] -> "world"
          match?([%{id: _} | _], socket.assigns.cast) -> hd(socket.assigns.cast).id
          true -> "world"
        end
    end
  end

  # ── Reviewing ─────────────────────────────────────────────────────────────────

  def handle_event("accept", %{"id" => id}, socket),
    do: act(socket, &ArcEntryRepo.accept(Repo, &1), id, "Made true.")

  def handle_event("reject", %{"id" => id}, socket),
    do: act(socket, &ArcEntryRepo.reject(Repo, &1), id, "Left as it was.")

  # Accept everything for one subject — the row's own fast path, and what the scene
  # gate's "accept all and carry on" resolves to.
  def handle_event("accept_all", %{"subject" => subject}, socket) do
    safe(socket, fn ->
      type = if subject == socket.assigns.campaign_id, do: "world", else: "character"
      count = ArcEntryRepo.accept_all(Repo, subject, type)

      {:noreply, socket |> put_flash(:info, made_true(count)) |> load()}
    end)
  end

  def handle_event("accept_group", %{"id" => id}, socket) do
    safe(socket, fn ->
      count = Polyphony.Authoring.GroupArc.accept_all(id)
      {:noreply, socket |> put_flash(:info, made_true(count)) |> load()}
    end)
  end

  def handle_event("edit", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing: String.to_integer(id))}

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  def handle_event("save_edit", %{"entry_id" => id} = params, socket) do
    safe(socket, fn ->
      attrs = %{statement: params["statement"]}

      attrs =
        if params["scope"] in [nil, ""], do: attrs, else: Map.put(attrs, :scope, params["scope"])

      ArcEntryRepo.edit(Repo, String.to_integer(id), attrs)

      {:noreply, socket |> assign(editing: nil) |> put_flash(:info, "Updated.") |> load()}
    end)
  end

  def handle_event("drawer", _params, socket),
    do: {:noreply, assign(socket, drawer: not socket.assigns.drawer)}

  defp act(socket, fun, id, msg) do
    safe(socket, fn ->
      fun.(String.to_integer(id))
      {:noreply, socket |> assign(editing: nil) |> put_flash(:info, msg) |> load()}
    end)
  end

  defp made_true(1), do: "1 change made true."
  defp made_true(n), do: "#{n} changes made true."

  # ── Render ────────────────────────────────────────────────────────────────────

  def render(assigns) do
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
    <Kit.sheet class="mx-4 mt-4">
      <Kit.row class="px-4 py-3 flex items-center justify-between" style="background:var(--b2)">
        <span class="ttl text-[15px] font-semibold">About this</span>
        <button
          type="button"
          class="dim text-[17px] leading-none"
          phx-click="drawer"
          aria-label="Close"
        >
          ×
        </button>
      </Kit.row>
      <Kit.row class="px-4 py-3">
        <p class="text-[13px] leading-relaxed">
          A scene closed and the engine worked out what it changed. Nothing here is true
          until you say so, and nothing is lost if you leave it.
        </p>
      </Kit.row>
      <Kit.row class="px-4 py-3">
        <div class="flex items-center gap-1.5 mb-1">
          <Kit.dot colour="var(--lamp)" />
          <span class="text-[13px] font-semibold">Why it holds up a new scene</span>
        </div>
        <p class="text-[13px] leading-relaxed">
          Generation works from the sheet. An unreviewed change is a gap between who
          someone is on paper and who they've become — let it run and the Director is
          writing someone who stopped existing two scenes ago. Only the cast you're about
          to use has to be current.
        </p>
      </Kit.row>
      <div class="px-4 py-3">
        <div class="flex items-center gap-1.5 mb-1">
          <Kit.dot colour="var(--ok)" />
          <span class="text-[13px] font-semibold">Accept all is the fast path</span>
        </div>
        <p class="text-[13px] leading-relaxed">
          It's meant to be used. The gate exists to keep things consistent, not to make
          you read carefully — one tap still leaves you with sheets that match your story.
        </p>
      </div>
    </Kit.sheet>
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
