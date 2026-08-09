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

  alias Polyphony.{Accounts, Library, Moderation, Permissions, Reading}
  alias Polyphony.Owner
  alias PolyphonyCore.Publication
  alias Polyphony.Reading.Session
  alias PolyphonyWeb.Screens

  @tabs ~w(stories worlds)

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, page_title: "Browse", reporting: false, sort: "any", who: nil, info: false)}
  end

  # Everything is in the URL: which story, which scene, which perspective. A reading
  # position you can't link to isn't one you can come back to, and the bookmark
  # (§3.1e) stores exactly these three.
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(tab: if(params["tab"] in @tabs, do: params["tab"], else: "stories"))
      |> assign(story_id: params["story"], scene_id: params["scene"])
      |> remember_token(params["t"])
      |> load()
      |> assign_mode(params["as"])
      |> load_scene()

    {:noreply, socket}
  end

  # ── Loading ──────────────────────────────────────────────────────────────────

  # A share token is a grant, and it arrives once — on the hand-off from `/s/:token`.
  # Every move inside a story after that is a `patch`, which keeps this process, so the
  # grant is held here rather than re-appended to each link. Reading a `nil` param must
  # not clear one: `handle_params` runs on every patch, and the perspective picker would
  # otherwise revoke the reader's own access on their first click.
  defp remember_token(socket, nil), do: assign_new(socket, :token, fn -> nil end)
  defp remember_token(socket, token), do: assign(socket, token: token)

  defp load(socket) do
    entry = socket.assigns.story_id && Library.get(socket.assigns.story_id)
    story = if readable?(socket, entry), do: entry, else: nil

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
  # Two questions, and only one of them is a permission. `snapshot?` is what this screen
  # is *for* — a live campaign is somebody's working copy, not a story, and opening one
  # here would read its scene list as a published contents. `can_view?/3` is the other
  # half: may this reader have it. They used to be one function in `Screens.Browse`,
  # which is how a presentation module came to hold the rule about who may read an
  # unlisted story, and to get it wrong.
  defp readable?(_socket, nil), do: false

  defp readable?(socket, entry) do
    Library.snapshot?(entry) and
      Permissions.can_view?(entry, socket.assigns.current_user, token: grant(socket, entry))
  end

  # The token the reader arrived with — or, if they didn't but they have a bookmark for
  # this story, the entry's own. **A bookmark stands in for the link they were given.**
  # `Reading` had already decided that and its shelf says so: a story you were reading
  # stays on it when the author moves it from public to unlisted, because narrowing who
  # can *find* something is not evicting the people already inside. Browse has to agree
  # or the shelf offers a *carry on* that dead-ends on arrival.
  #
  # Handing the token to `can_view?/3` rather than short-circuiting the check is what
  # keeps the limit: a token means nothing for a `private` entry, so an author who pulls
  # a story back properly still shuts the door on everyone — which is exactly what the
  # shelf reports for the same story.
  #
  # It cannot be forged. `Reading.mark/4` is called from one place, after this function
  # has already admitted the reader, so holding a bookmark is evidence of having been let
  # in rather than a way of claiming to have been.
  defp grant(%{assigns: %{token: token}}, _entry) when not is_nil(token), do: token
  defp grant(%{assigns: %{current_user: nil}}, _entry), do: nil

  defp grant(socket, entry) do
    case Reading.bookmark(Owner.of(socket.assigns.current_user), entry.id) do
      nil -> nil
      _bookmark -> entry.share_token
    end
  end

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
      case scene && gap == nil && Reading.scene(snapshot, scene_id, mode) do
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

  # The drawer behind the ⓘ on the perspective control — opened from the selector,
  # never pushed at anybody (no toast on switch; it gets irritating by the second one).
  def handle_event("reading_as_info", _params, socket),
    do: {:noreply, assign(socket, info: true)}

  def handle_event("close_info", _params, socket), do: {:noreply, assign(socket, info: false)}

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
  # reader's library as a new original — **whole**. There is no partial copy and no
  # permission tier inside a world: everything the author wrote comes across, including
  # entries kept from the reader while they were reading. What does not come across is
  # the arc, and that needs no stripping here — the arc lives outside the bible, so the
  # embedded copy is already the world at scene one, before anything in the story
  # happened to it (STR-63; the screen says both halves).
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
            payload: bible
          })

          {:noreply,
           put_flash(
             socket,
             :info,
             "A copy is in your library — the world as it began, not as the story left it."
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

  # The id comes off a `phx-value-id` on a row the catalogue rendered, which is to say it
  # comes from the client and the rows are not the limit of what can be sent. Taking
  # *copies*, payload and all, so an unchecked id here was a way to lift a private world
  # — secrets included — straight out of somebody else's library, and the same hole for
  # a private campaign. `CampaignLive.attach_world/2` had already worked this out and
  # checks; this path is the one that didn't, which is the whole argument for one gate
  # rather than a check at each site that remembers.
  #
  # `can_view?/3` is the right bar rather than ownership: taking a copy of what you may
  # read is the product (§2.5b). It is what you may read that was never being asked.
  defp copy_into(socket, id, user, message) do
    source = Library.get(id)

    cond do
      is_nil(source) ->
        put_flash(socket, :error, "That's gone.")

      not Permissions.can_view?(source, user, token: socket.assigns.token) ->
        put_flash(socket, :error, "That isn't yours to take.")

      true ->
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
      info={@info}
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
      token={@token}
      who={@who}
      worlds={@worlds}
    />
    """
  end
end
