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

  alias Polyphony.{Campaigns, Characters, Groups, Library, Reading}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, Group}
  alias Polyphony.Reading.Session
  alias Polyphony.Permissions
  alias PolyphonyWeb.{Screens, Voice}

  @tabs ~w(campaigns reading worlds people groups shelves)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Library", query: "", tier: "all", menu_for: nil)
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
    |> assign(
      # Decorated here rather than in the markup: the name and the line both come off a
      # library entry's payload, and a screen renders from assigns.
      archived: Enum.map(Library.archived(owner), &shelf_row(&1, :archived)),
      trashed: Enum.map(Library.trash(owner), &shelf_row(&1, :trashed))
    )
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
      named?: Screens.Library.named?(payload),
      status: status,
      status_label: Campaigns.status_label(status),
      # Publishing freezes a *copy*, so the campaign here is still live and playable —
      # what's published is a separate entry descended from it (§3.1d).
      published?: Library.published?(entry),
      world: world_name(by_id, payload),
      people: length(Map.get(payload, :character_ids) || []),
      scenes: length(Map.get(payload, :scenes) || []),
      premise: Screens.Library.blank_to_nil(Map.get(payload, :premise)),
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
        named?: Screens.Library.named?(payload),
        visibility: entry.visibility,
        blurb:
          Screens.Library.blank_to_nil(Map.get(payload, :cover)) ||
            Screens.Library.blank_to_nil(Map.get(payload, :premise)),
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
      role: Screens.Library.blank_to_nil(Map.get(sheet, :premise)),
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
      # Resolved here rather than in the markup: unwrapping a library entry is the
      # screen reading, and the rest of the row is already decorated at this point.
      name: reading_name(row),
      place: reading_place(row),
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
      nil ->
        nil

      id ->
        with entry when not is_nil(entry) <- Map.get(by_id, to_int(id)),
             do: entry_name(entry)
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

  defp mutate(socket, id, note, fun) do
    safe(socket, fn ->
      entry = Library.get(id, include_archived: true, include_deleted: true)

      if Permissions.can_edit?(entry, socket.assigns.current_user) do
        fun.(id)
        {:noreply, socket |> assign(menu_for: nil) |> put_flash(:info, note) |> load()}
      else
        {:noreply, socket |> assign(menu_for: nil) |> put_flash(:error, "Not found.")}
      end
    end)
  end

  # One row's menu at a time, held by id rather than by a `<details>` per row: the panel
  # is an overlay now, and two open at once would stack.
  def handle_event("row_menu", %{"id" => id}, socket),
    do: {:noreply, assign(socket, menu_for: to_string(id))}

  def handle_event("close_row_menu", _params, socket),
    do: {:noreply, assign(socket, menu_for: nil)}

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
  def handle_event("unarchive", %{"id" => id}, socket),
    do: mutate(socket, id, "Back on the shelf.", &Library.unarchive/1)

  def handle_event("archive", %{"id" => id}, socket),
    do: mutate(socket, id, "Filed. It's on the archive shelf.", &Library.archive/1)

  # Soft, and on a clock — `Library.purge_expired/1` is what finally removes it, and
  # the trash shelf carries the one irreversible button in the screen.
  def handle_event("trash", %{"id" => id}, socket),
    do: mutate(socket, id, "In the trash. You can put it back.", &Library.soft_delete/1)

  def handle_event("restore", %{"id" => id}, socket),
    do: mutate(socket, id, "Put back.", &Library.restore/1)

  # The one irreversible button in the screen, and the only one that confirms.
  def handle_event("purge", %{"id" => id}, socket),
    do: mutate(socket, id, "Gone for good.", &Library.purge/1)

  def handle_event("forget_reading", %{"id" => id}, socket) do
    safe(socket, fn ->
      {:ok, _} = Library.soft_delete(id)
      {:noreply, load(socket)}
    end)
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <Screens.Library.screen
      current_user={@current_user}
      entries={@entries}
      tab={@tab}
      menu_for={@menu_for}
      query={@query}
      tier={@tier}
      campaigns={@campaigns}
      worlds={@worlds}
      people={@people}
      groups={@groups}
      reading={@reading}
      archived={@archived}
      trashed={@trashed}
    />
    """
  end

  defp reading_name(%{source: nil}), do: "A story you were reading"
  defp reading_name(%{source: source}), do: Session.title(Library.payload(source))

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
      {i, n} ->
        "Scene #{i} of #{n}."

      # The one place the republish trade shows: there is a single published copy and
      # updating it replaces what a reader was in the middle of. Usually the story just
      # got longer and the scene id still resolves; when it doesn't, say so rather than
      # quietly starting them over.
      nil ->
        if row.bookmark.scene_id,
          do: "The scene you were on isn't in this version any more.",
          else: "Partway through."
    end
  end

  defp shelf_row(entry, :archived),
    do: %{
      id: entry.id,
      kind: entry.kind,
      name: entry_name(entry),
      line: archived_line(entry),
      colour: entry_colour(entry)
    }

  defp shelf_row(entry, :trashed),
    do: %{
      id: entry.id,
      kind: entry.kind,
      name: entry_name(entry),
      line: countdown(entry),
      colour: entry_colour(entry)
    }

  def entry_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> untitled(entry.kind)
    end
  end

  defp archived_line(entry) do
    [kind_label(entry.kind), month_of(entry.archived_at)]
    |> Enum.filter(& &1)
    |> Enum.join(" · archived in ")
  end

  defp countdown(entry) do
    case Library.days_until_purge(entry) do
      nil -> "Waiting to be purged"
      0 -> "Gone for good today"
      1 -> "Gone for good tomorrow"
      n -> "Gone for good in #{n} days"
    end
  end

  # ── Reading copy ─────────────────────────────────────────────────────────────

  defp kind_label("world_bible"), do: "World"

  defp kind_label("character"), do: "Character"

  defp kind_label("campaign"), do: "Campaign"

  defp kind_label(kind), do: String.capitalize(to_string(kind))

  defp month_of(nil), do: nil

  defp month_of(at), do: Calendar.strftime(at, "%B")

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
end
