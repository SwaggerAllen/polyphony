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

  alias Polyphony.{Accounts, Branching, Library, Moderation, Permissions, Reading}
  alias Polyphony.Owner
  alias PolyphonyCore.Publication
  alias Polyphony.Reading.Session
  alias PolyphonyWeb.Screens

  @tabs ~w(stories worlds)

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Browse",
       reporting: false,
       sort: "any",
       who: nil,
       info: false,
       off_canon_open: false,
       diverged: nil
     )}
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
    |> assign_diverged_pending()
  end

  # Is this reader's place in a line the story has moved on from? Asked once per
  # line, not once per visit: a bookmark that recorded *stay* for this line has
  # answered, and the dialog stays away (browse.md, `continue_reading_diverged`).
  defp assign_diverged_pending(socket) do
    %{snapshot: snapshot, bookmark: bookmark} = socket.assigns

    pending =
      with %{} = snap <- snapshot,
           %{scene_id: sid} = b when not is_nil(sid) <- bookmark,
           %{} = line <- Session.line_for_scene(snap, sid),
           true <- to_string(Map.get(line, :id)) != to_string(b.stayed_line_id || "") do
        shared = Session.shared_point(snap, line)

        %{
          line_id: Map.get(line, :id),
          shared_point: (shared && Map.get(shared, :title)) || "the beginning",
          shared_scene_id: shared && Session.scene_id(shared),
          author: socket.assigns.row && socket.assigns.row.author
        }
      else
        _ -> nil
      end

    assign(socket, diverged_pending: pending, diverged: nil)
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
    do:
      assign(socket,
        events: [],
        scene: nil,
        gap: nil,
        names: %{},
        who: nil,
        off_canon: nil,
        gone_notice: nil
      )

  defp load_scene(%{assigns: %{scene_id: nil}} = socket),
    do:
      assign(socket,
        events: [],
        scene: nil,
        gap: nil,
        names: Session.names(socket.assigns.snapshot),
        off_canon: nil,
        gone_notice: nil
      )

  # Which line is this? The published contents are the canonical line; the other
  # lines travel unlisted in the snapshot, reachable by a link somebody was sent;
  # a scene in neither is gone, and the answer depends on *how* it went.
  defp load_scene(socket) do
    %{snapshot: snapshot, scene_id: scene_id} = socket.assigns

    case Session.line_for_scene(snapshot, scene_id) do
      :canonical ->
        socket
        |> assign(off_canon: nil, gone_notice: nil)
        |> load_scene_at(scene_id, nil)

      %{} = line ->
        socket |> assign(gone_notice: nil) |> load_line_scene(scene_id, line)

      nil ->
        resolve_gone(socket)
    end
  end

  # Reading a line that isn't the current one (browse.md, `reading_off_canon`):
  # the pill states it, neutral rather than gold — a reader following a link they
  # were sent is exactly where somebody meant them to be.
  defp load_line_scene(socket, scene_id, line) do
    shared = Session.shared_point(socket.assigns.snapshot, line)

    socket
    |> assign(
      off_canon: %{
        author: socket.assigns.row.author,
        shared_point: (shared && Map.get(shared, :title)) || "the beginning",
        shared_scene_id: shared && Session.scene_id(shared),
        open: socket.assigns.off_canon_open
      }
    )
    |> load_scene_at(scene_id, line)
  end

  defp load_scene_at(socket, scene_id, line) do
    %{snapshot: snapshot, mode: mode} = socket.assigns

    scenes = if line, do: Map.get(line, :scenes) || [], else: Session.scenes(snapshot)
    scene = Enum.find(scenes, &(Session.scene_id(&1) == to_string(scene_id)))

    # Copy-on-branch means this line's people are different library ids for the
    # same folk. The grant is checked in canonical's ids (the publication's), the
    # projection runs in the line's own — `heads` is the translation both ways.
    heads = (line && Map.get(line, :heads)) || %{}
    unheads = Map.new(heads, fn {canon, local} -> {local, canon} end)

    gap = scene && Session.gap(snapshot, uncopy_cast(scene, unheads), mode)

    events =
      case scene && gap == nil &&
             Reading.scene(snapshot, scene_id, mode, viewer: local_viewer(snapshot, mode, heads)) do
        {:ok, events} -> events
        _ -> []
      end

    names = Map.merge(Session.names(snapshot), (line && Map.get(line, :names)) || %{})

    socket
    # A new scene closes an open card — it was about somebody in the one you left.
    |> assign(scene: scene, gap: gap, events: events, names: names, who: nil)
    |> mark_place()
  end

  defp uncopy_cast(scene, unheads) when map_size(unheads) == 0, do: scene

  defp uncopy_cast(scene, unheads),
    do: Map.put(scene, :cast, Enum.map(Map.get(scene, :cast) || [], &Map.get(unheads, &1, &1)))

  defp local_viewer(snapshot, mode, heads) do
    case Publication.viewer(Session.publication(snapshot), mode) do
      {:character, id} -> {:character, Map.get(heads, to_string(id), id)}
      viewer -> viewer
    end
  end

  # The link names a scene the snapshot no longer tells, on any line. Two honest
  # answers, neither of them a 404 (browse.md, `scene_gone` / `branch_gone`) —
  # the branch read models are consulted for *where things went*, never for
  # content: the snapshot stays the only thing a reader is shown.
  defp resolve_gone(socket) do
    %{snapshot: snapshot, row: row} = socket.assigns
    campaign_id = Map.get(snapshot, :campaign_id)

    case campaign_id && Branching.resolve_scene(campaign_id, socket.assigns.scene_id) do
      # The line survives; the scene was tidied out of it. Land at the line's
      # earliest change — the cursor — the last point the reader can trust.
      {:ok, line} ->
        land(socket, line.cursor_scene_id, %{kind: :scene, author: row.author})

      # The line itself was deleted. The tombstone walk found the nearest
      # surviving ancestor and the last content the link promised.
      {:moved, _ancestor, landing_scene} ->
        land(socket, landing_scene, %{kind: :branch, author: row.author})

      # Nothing here ever held that scene — the republished-away bookmark case,
      # answered as before: back to the front page's fallback.
      _ ->
        assign(socket,
          scene: nil,
          gap: nil,
          events: [],
          names: Session.names(snapshot),
          off_canon: nil,
          gone_notice: nil
        )
    end
  end

  # Land somewhere real, say what happened, and keep the two states composable:
  # where the reader lands may itself be off-canon, in which case the pill
  # applies on top of the notice.
  defp land(socket, landing_scene, notice) do
    snapshot = socket.assigns.snapshot

    landing =
      if landing_scene && Session.line_for_scene(snapshot, landing_scene) != nil do
        to_string(landing_scene)
      else
        snapshot |> Session.scenes() |> List.first() |> then(&(&1 && Session.scene_id(&1)))
      end

    case landing do
      nil ->
        assign(socket,
          scene: nil,
          gap: nil,
          events: [],
          names: Session.names(snapshot),
          off_canon: nil,
          gone_notice: nil
        )

      landing ->
        socket
        |> assign(scene_id: landing)
        |> load_scene()
        |> assign(gone_notice: notice)
    end
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

  # ── Which line is this (STR-8) ───────────────────────────────────────────────

  # The off-canon pill explains on tap, never unprompted — it is a fact, not a
  # warning, and the explanation lives where somebody curious would go looking.
  def handle_event("off_canon_open", _params, socket) do
    {:noreply,
     socket
     |> assign(off_canon_open: true)
     |> update(:off_canon, &(&1 && %{&1 | open: true}))}
  end

  def handle_event("off_canon_close", _params, socket) do
    {:noreply,
     socket
     |> assign(off_canon_open: false)
     |> update(:off_canon, &(&1 && %{&1 | open: false}))}
  end

  # The switch lands at the last point the two lines share — everything before it
  # is identical, so there is no reason to make anybody read it twice.
  def handle_event("switch_to_current", _params, socket) do
    %{story: story, snapshot: snapshot, mode: mode, off_canon: off_canon} = socket.assigns

    landing =
      (off_canon && off_canon.shared_scene_id) ||
        snapshot |> Session.scenes() |> List.first() |> then(&(&1 && Session.scene_id(&1)))

    case landing do
      nil ->
        {:noreply, socket |> assign(off_canon_open: false) |> push_patch(to: front_url(story))}

      scene ->
        {:noreply,
         socket
         |> assign(off_canon_open: false)
         |> push_patch(to: scene_url(story, scene, mode))}
    end
  end

  # Continue reading, on a story that has moved on: the dialog is opened by the
  # tap, not pushed at anybody on arrival.
  def handle_event("carry_on_diverged", _params, socket) do
    case socket.assigns.diverged_pending do
      nil ->
        {:noreply, socket}

      pending ->
        {:noreply,
         assign(socket, diverged: %{shared_point: pending.shared_point, author: pending.author})}
    end
  end

  # Read the current version: land where the two last agree. The old position
  # stands in the bookmark until the new scene writes over it — nothing is moved
  # until the reader chooses.
  def handle_event("continue_current", _params, socket) do
    %{story: story, snapshot: snapshot, mode: mode, diverged_pending: pending} = socket.assigns

    landing =
      (pending && pending.shared_scene_id) ||
        snapshot |> Session.scenes() |> List.first() |> then(&(&1 && Session.scene_id(&1)))

    case landing do
      nil ->
        {:noreply, assign(socket, diverged: nil)}

      scene ->
        {:noreply,
         socket
         |> assign(diverged: nil, diverged_pending: nil)
         |> push_patch(to: scene_url(story, scene, mode))}
    end
  end

  # Carry on where I was — available and unstigmatised, and remembered per line so
  # the question is never asked twice about the same choice.
  def handle_event("continue_anyway", _params, socket) do
    %{story: story, bookmark: bookmark, mode: mode, diverged_pending: pending} = socket.assigns

    if socket.assigns.current_user && pending do
      Reading.stay(Owner.of(socket.assigns.current_user), story.id, pending.line_id)
    end

    case bookmark && bookmark.scene_id do
      nil ->
        {:noreply, assign(socket, diverged: nil, diverged_pending: nil)}

      scene ->
        {:noreply,
         socket
         |> assign(diverged: nil, diverged_pending: nil)
         |> push_patch(to: scene_url(story, scene, mode))}
    end
  end

  # Carrying on from a landing needs no navigation — the reader is already there;
  # the notice has said its piece.
  def handle_event("dismiss_gone", _params, socket),
    do: {:noreply, assign(socket, gone_notice: nil)}

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

  defp front_url(story), do: ~p"/browse?#{[story: story.id]}"

  defp scene_url(story, scene_id, mode),
    do: ~p"/browse?#{[story: story.id, scene: scene_id, as: mode && Publication.to_param(mode)]}"

  def render(assigns) do
    ~H"""
    <Screens.Browse.screen
      current_user={@current_user}
      bookmark={@bookmark}
      diverged={@diverged}
      diverged_pending={@diverged_pending}
      events={@events}
      gap={@gap}
      gone={@gone}
      gone_notice={@gone_notice}
      info={@info}
      mode={@mode}
      names={@names}
      off_canon={@off_canon}
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
