defmodule PolyphonyWeb.BrowseLive do
  @moduledoc """
  Browse and read published campaigns, ported from `ux/polyphony-browse.html` —
  *reading someone else's*.

  Publishing worked and produced nothing anyone could read; Browse was bare title
  cards. This is the missing half, and **the perspective picker is the whole draw**,
  because no other reading app can offer the same scene from three heads.

  ## Four states, one screen

  The list, a story's front page, the reading view, and taking something with you. They
  share a screen because they're one continuous act — you don't navigate to a reader,
  you start reading.

  ## Choosing how to read comes before reading

  It's the first real decision, and putting it up front is what stops the perspective
  picker feeling like a settings menu. *Everyone the author shared* leads where it
  exists: it needs no choice from the reader and it's the only mode that reads like
  fiction rather than a record (§3.1b).

  ## The reading view is the play screen with a different bottom bar

  Same header, same perspective control, same transcript, same beat rules — only the
  composer is replaced, by scene navigation. It takes the `.page` register, because it
  isn't an authoring surface, it's a way of reading.

  ## Two different kinds of empty

  *Halden wasn't here* is a fact about the reader's perspective and has a way out —
  switch, or carry on. *This one isn't shared* is a fact about the publication and
  doesn't. Both are **shown rather than skipped**: silently dropping a scene would make
  the numbering lie and the story jump (§3.1c-ii).

  ## Reading never hits a wall

  Only the actions do. A signed-out reader gets the story; taking a copy or reading as
  someone in it needs an account, and that's said once, plainly, at the point it
  matters.
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{Accounts, Library, Moderation, Owner, Publication, Reading}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Reading.Session
  alias PolyphonyWeb.Screens

  @tabs ~w(stories worlds)

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Browse", reporting: false, sort: "any", who: nil)}
  end

  # Everything is in the URL: which story, which scene, which perspective. A reading
  # position you can't link to isn't one you can come back to, and the bookmark
  # (§3.1e) stores exactly these three.
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(tab: if(params["tab"] in @tabs, do: params["tab"], else: "stories"))
      |> assign(story_id: params["story"], scene_id: params["scene"])
      |> load()
      |> assign_mode(params["as"])
      |> load_scene()

    {:noreply, socket}
  end

  # ── Loading ──────────────────────────────────────────────────────────────────

  defp load(socket) do
    entry = socket.assigns.story_id && Library.get(socket.assigns.story_id)
    story = if entry && Screens.Browse.published?(entry), do: entry, else: nil

    socket
    |> assign(
      story: story,
      # `@story` is a raw entry here and a *row* on the listing — the front page takes
      # its row explicitly so the screen never has to tell them apart, or unwrap one.
      row: story && story_row(story),
      snapshot: story && Library.payload(story)
    )
    |> assign(gone: gone_reason(socket.assigns.story_id, entry, story))
    |> assign(bookmark: bookmark_for(socket, story))
    |> assign(stories: story_rows(), worlds: world_rows())
  end

  # A link that named a story and didn't get one has to say so. Dropping the reader on
  # the catalogue reads as "you clicked the wrong thing", which is the one thing that
  # didn't happen — and a bookmark to a republished-away scene lands here too.
  #
  # Taken-down is its own answer rather than folded into "gone", because the author
  # follows the same link, finds their own copy missing as well, and needs to know why
  # (§B3 — a take-down takes everything).
  defp gone_reason(nil, _entry, _story), do: nil
  defp gone_reason(_id, _entry, story) when not is_nil(story), do: nil

  defp gone_reason(_id, entry, _story),
    do: if(entry && Library.hidden?(entry), do: :down, else: :gone)

  # Grouped by root (§3.1d), because three forks share a title until someone renames
  # one — a flat list of near-identical names is unusable. Author is the delineator.
  defp story_rows do
    "campaign"
    |> Library.list_public()
    |> Enum.filter(& &1.frozen)
    |> Enum.group_by(&Library.root_of/1)
    |> Enum.map(fn {_root, entries} ->
      [first | rest] = Enum.sort_by(entries, & &1.inserted_at, NaiveDateTime)
      %{lead: story_row(first), forks: Enum.map(rest, &story_row/1)}
    end)
    |> Enum.sort_by(&(-&1.lead.scenes))
  end

  defp story_row(entry) do
    snapshot = Library.payload(entry) || %{}
    pub = Session.publication(snapshot)
    scenes = Session.scenes(snapshot)
    cast = Enum.map(Map.get(snapshot, :characters) || [], &Map.get(&1, :source_id))

    %{
      id: entry.id,
      name: Screens.Browse.story_name(snapshot),
      author: author_of(entry),
      blurb: Screens.Browse.blurb(snapshot),
      scenes: length(scenes),
      pub: pub,
      heads: length(pub.perspectives),
      withheld: Publication.withheld(pub, cast),
      copies: Library.copy_count(entry.id)
    }
  end

  defp world_rows do
    "world_bible"
    |> Library.list_public()
    |> Enum.map(fn entry ->
      payload = Library.payload(entry) || %{}

      %{
        id: entry.id,
        name: Map.get(payload, :name) || "Untitled world",
        author: author_of(entry),
        # Only the cover — the outward blurb written under instruction to give none of
        # the world's secrets away (§2.12). Never the bible itself.
        cover: Map.get(payload, :cover),
        taken: Library.copy_count(entry.id)
      }
    end)
  end

  # The reader's mode, defaulting to what the publication leads with. An `as` the
  # publication never granted falls back rather than erroring — a stale link is a
  # normal thing to have, and default-deny already refuses to show anything extra.
  defp assign_mode(socket, as) do
    case socket.assigns.snapshot do
      nil ->
        assign(socket, mode: nil, pub: nil)

      snapshot ->
        pub = Session.publication(snapshot)

        # The URL wins, then where they were last time, then what the publication leads
        # with. Coming back into a different head is coming back to a different story,
        # so a bookmark is a stronger signal than a default (§3.1e).
        mode =
          [Publication.from_param(as), bookmarked_mode(socket), Publication.default_mode(pub)]
          |> Enum.find(&(&1 && Publication.offers?(pub, &1)))

        assign(socket, pub: pub, mode: mode)
    end
  end

  defp load_scene(%{assigns: %{snapshot: nil}} = socket),
    do: assign(socket, events: [], scene: nil, gap: nil, names: %{}, who: nil)

  defp load_scene(%{assigns: %{scene_id: nil}} = socket),
    do:
      assign(socket,
        events: [],
        scene: nil,
        gap: nil,
        names: Session.names(socket.assigns.snapshot)
      )

  defp load_scene(socket) do
    %{snapshot: snapshot, scene_id: scene_id, mode: mode} = socket.assigns

    scene =
      snapshot
      |> Session.scenes()
      |> Enum.find(&(to_string(Map.get(&1, :id)) == to_string(scene_id)))

    gap = scene && Session.gap(snapshot, scene, mode)

    events =
      case scene && gap == nil && Session.scene(snapshot, scene_id, mode) do
        {:ok, events} -> events
        _ -> []
      end

    socket
    # A new scene closes an open card — it was about somebody in the one you left.
    |> assign(scene: scene, gap: gap, events: events, names: Session.names(snapshot), who: nil)
    |> mark_place()
  end

  # Keeping the place is the one thing the reading shelf promises (§3.1e), so it's
  # written on arrival rather than on leaving — a reader who closes the tab mid-scene
  # is exactly the one who needs it.
  defp mark_place(%{assigns: %{current_user: nil}} = socket), do: socket

  defp mark_place(socket) do
    %{story: story, scene: scene, mode: mode} = socket.assigns

    if story && scene do
      Reading.mark(Owner.of(socket.assigns.current_user), story.id, %{
        scene_id: Map.get(scene, :id),
        perspective: Publication.to_param(mode)
      })
    end

    socket
  end

  # Where this reader left off, if they've been here before. Nil for a signed-out
  # visitor, who has no shelf to keep a place on. Read once per mount rather than per
  # render, since three parts of the front page ask about it.
  defp bookmark_for(%{assigns: %{current_user: user}}, story)
       when not is_nil(user) and not is_nil(story),
       do: Reading.bookmark(Owner.of(user), story.id)

  defp bookmark_for(_socket, _story), do: nil

  defp bookmarked_mode(socket),
    do: socket.assigns[:bookmark] && Publication.from_param(socket.assigns.bookmark.perspective)

  # ── Events ───────────────────────────────────────────────────────────────────

  # The name in the transcript. A reader meets six names in two pages and had no way to
  # ask who any of them are without leaving the story.
  def handle_event("who", %{"id" => id}, socket),
    do: {:noreply, assign(socket, who: Screens.Browse.who_card(socket.assigns.snapshot, id))}

  def handle_event("close_who", _params, socket), do: {:noreply, assign(socket, who: nil)}

  def handle_event("report", _params, socket),
    do: {:noreply, assign(socket, reporting: true)}

  def handle_event("cancel_report", _params, socket),
    do: {:noreply, assign(socket, reporting: false)}

  # The moderation queue has been fully built and has never had a way in. Report
  # targets the **frozen snapshot**, so a take-down removes the public copy and leaves
  # the author's private original alone.
  def handle_event("send_report", params, socket) do
    safe(socket, fn ->
      story = socket.assigns.story

      case socket.assigns.current_user do
        nil ->
          {:noreply, put_flash(socket, :error, "Sign in to report something.")}

        user ->
          Moderation.file_report(user, %{
            item_type: "library_entry",
            item_id: story.id,
            owner_id: Screens.Browse.owner_id(story),
            reason: params["reason"],
            detail: params["detail"]
          })

          {:noreply,
           socket
           |> assign(reporting: false)
           |> put_flash(:info, "Reported. Thank you — a person reads every one of these.")}
      end
    end)
  end

  def handle_event("switch_mode", %{"as" => as}, socket) do
    story = socket.assigns.story
    scene = socket.assigns.scene

    {:noreply,
     push_patch(socket,
       to: ~p"/browse?#{[story: story.id, scene: Map.get(scene, :id), as: as]}"
     )}
  end

  # Three different appetites, all copies into the reader's library, all saying so
  # plainly. A character can't be taken on their own at all: lifted out of their
  # campaign they have no history and know nobody (§3.1c).
  def handle_event("take_world", %{"id" => id}, socket) do
    safe(socket, fn ->
      case socket.assigns.current_user do
        nil -> {:noreply, put_flash(socket, :error, "Sign in to take a copy.")}
        user -> {:noreply, copy_into(socket, id, user, "A copy is in your library.")}
      end
    end)
  end

  # Taking the world out of a *story* is not the same operation: the bible is embedded
  # in the frozen snapshot, so there's no library entry to copy. It is put into the
  # reader's library as a new original — and **stripped to its public entries**, because
  # what the author kept back was never shared and doesn't travel with the setting
  # (§2.17). Which is exactly what the screen says: some of this world isn't shown.
  def handle_event("take_story_world", _params, socket) do
    safe(socket, fn ->
      case {socket.assigns.current_user, Screens.Browse.embedded_bible(socket.assigns.snapshot)} do
        {nil, _} ->
          {:noreply, put_flash(socket, :error, "Sign in to take a copy.")}

        {_user, nil} ->
          {:noreply, put_flash(socket, :error, "There's no world attached to this one.")}

        {user, bible} ->
          Library.put(%{
            owner: Owner.of(user),
            kind: "world_bible",
            payload: WorldBible.stripped(bible)
          })

          {:noreply,
           put_flash(
             socket,
             :info,
             "A copy is in your library — minus whatever was kept back."
           )}
      end
    end)
  end

  def handle_event("fork", _params, socket) do
    safe(socket, fn ->
      story = socket.assigns.story

      cond do
        is_nil(socket.assigns.current_user) ->
          {:noreply, put_flash(socket, :error, "Sign in to carry this on.")}

        not Publication.forkable?(socket.assigns.pub) ->
          {:noreply, put_flash(socket, :error, "This one was shared to be read.")}

        true ->
          {:noreply,
           copy_into(socket, story.id, socket.assigns.current_user, "It's yours now — carry on.")}
      end
    end)
  end

  defp copy_into(socket, id, user, message) do
    case Library.get(id) do
      nil ->
        put_flash(socket, :error, "That's gone.")

      source ->
        Library.copy(source, Owner.of(user))
        put_flash(socket, :info, message)
    end
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  # No `nil` clause: both callers map over `Library.list_public/1`, so the entry is always
  # a row. The catch-all below still answers for one without a user owner.
  defp author_of(%{owner_type: "user", owner_id: id}) do
    case Accounts.get(id) do
      %{username: name} when is_binary(name) and name != "" -> "@" <> name
      _ -> "someone"
    end
  end

  defp author_of(_), do: "someone"

  def render(assigns) do
    ~H"""
    <Screens.Browse.screen
      current_user={@current_user}
      bookmark={@bookmark}
      events={@events}
      gap={@gap}
      gone={@gone}
      mode={@mode}
      names={@names}
      pub={@pub}
      reporting={@reporting}
      row={@row}
      scene={@scene}
      snapshot={@snapshot}
      stories={@stories}
      story={@story}
      tab={@tab}
      who={@who}
      worlds={@worlds}
    />
    """
  end
end
