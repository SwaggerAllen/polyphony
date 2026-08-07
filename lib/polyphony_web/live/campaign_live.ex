defmodule PolyphonyWeb.CampaignLive do
  @moduledoc """
  Campaign overview: the cast, the scenes, and the levers to start a scene or publish.
  Starting a scene opens the event-sourced stream, enters the cast, and seeds each
  character's frozen context so the Director loop can run.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias Polyphony.{Library, Context, App}
  alias Polyphony.Owner
  alias Polyphony.Permissions
  alias Polyphony.Context.{Store, PgvectorRetriever, Rebuild}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  alias Polyphony.Authoring.{
    CharacterSheet,
    Effective,
    Group,
    SceneGate,
    WorldBible
  }

  alias PolyphonyCore.Events.SceneOpened
  alias Polyphony.Groups
  alias Polyphony.Builds
  alias Polyphony.Generations
  alias Polyphony.Jobs.QuickBuild, as: BuildJob
  alias Polyphony.ReadModels.BuildRun
  alias Polyphony.Campaigns
  alias PolyphonyCore.Content.CampaignConfig
  alias PolyphonyCore.Publication
  alias Polyphony.Preflight
  alias PolyphonyWeb.Guard
  alias PolyphonyWeb.Screens
  alias PolyphonyWeb.Voice
  alias Polyphony.Director.SceneBrief
  alias Polyphony.LLM.Settings

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    # A frozen snapshot shares the `"campaign"` kind and nothing else — opening the
    # editor on one would try to read a cast and a premise off a `Library.Snapshot`.
    # It's a readable thing, so it goes where reading happens. A taken-down one is
    # gone, and says so in its own words.
    if entry && Campaigns.campaign?(entry) &&
         Permissions.can_edit?(entry, socket.assigns.current_user) do
      {:ok,
       socket
       |> assign(
         page_title: "Campaign",
         entry: entry,
         # Not `building: false` and a progress map. The build is a row now (§Builds),
         # so the socket holds a *view* of it that a reconnect re-reads rather than
         # state a reconnect loses.
         build: Builds.get(entry.id),
         expanding_premise: false,
         generating: false,
         # Nothing is granted until the author says so — the spoiler control has no
         # clever default (§3.1). Spectator starts on because it's the one setting
         # that reveals nothing, not because it's the best read.
         pub_perspectives: [],
         pub_spectator: true,
         pub_forkable: false,
         qb_world: "",
         qb_seeds: [""],
         qb_suggest: true,
         qb_groups: false,
         quick_build_open: false,
         viewer: :omniscient,
         writing_in: MapSet.new(),
         publish_help: false,
         scene_location: "",
         scene_premise: "",
         scene_suggesting: false,
         # Who is in the *next* scene. Nil means "everyone who's ready", which is what
         # this always did — a set only exists once the author has said otherwise, so
         # a cast that grows between scenes is included by default rather than silently
         # left out of the selection made three scenes ago.
         scene_cast: nil,
         tab: "settings"
       )
       |> subscribe_build(entry)
       |> restore_generations(entry)
       |> load()}
    else
      redirect_missing(socket, entry)
    end
  end

  # A take-down removes the thing, not its listing — so this is the deleted experience
  # with the one difference that matters: they're told why, and where the rest of it is.
  defp redirect_missing(socket, entry),
    do: Guard.refuse(socket, entry, "Campaign", socket.assigns.current_user)

  # The tab lives in the URL, so it's linkable, survives a reload, and back works
  # between sections of a screen that used to be one long scroll.
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(tab: tab_param(params["tab"]), viewer: viewer_param(socket, params))
     |> assign_seen()}
  end

  # The perspective control's state, in the URL for the same reason play keeps it there:
  # a viewpoint is part of *what you are looking at*, so it survives a reload and a
  # shared link, and switching it is a patch rather than a remount.
  #
  # Only a **castable** member is a valid viewpoint. A stub has no knowledge to speak
  # of, and offering one would be offering a view that answers every question the same
  # way — and an id that isn't on this roster is refused rather than trusted, because
  # this is the control that decides what secrets are on the screen.
  defp viewer_param(socket, params) do
    ids =
      for c <- socket.assigns.cast,
          Screens.Campaign.full?(c),
          into: MapSet.new(),
          do: to_string(c.id)

    case params["as"] do
      id when is_binary(id) -> if MapSet.member?(ids, id), do: {:character, id}, else: :omniscient
      _ -> :omniscient
    end
  end

  # The viewer decides what a *world* read shows. Omniscient is the author over their
  # own world and sees everything, with concealed entries marked; a character sees what
  # `Audience` says they know, resolved through their groups.
  # The world as the current viewer knows it. A read — `for_character/2` resolves group
  # membership live — so it is answered here and handed over as `seen`, rather than
  # derived inside the markup where it ran on every render.
  defp assign_seen(socket), do: assign(socket, seen: viewed_world(socket.assigns))

  defp viewed_world(%{world: nil}), do: nil
  defp viewed_world(%{viewer: :omniscient, world: world}), do: world

  # No `:owner` opt: that one names the character a *fact* is about, and world entries
  # are about the world. Group membership still resolves — `Audience.resolve/2` expands
  # `group_ids` live, which is the whole reason a group is somewhere for a secret to
  # point rather than a list of names frozen at writing time.
  defp viewed_world(%{viewer: {:character, id}, world: world}),
    do: WorldBible.for_character(world, id)

  defp tab_param(tab) do
    if Enum.any?(Screens.Campaign.tabs(), fn {slug, _} -> slug == tab end),
      do: tab,
      else: "settings"
  end

  defp load(socket) do
    payload = Library.payload(socket.assigns.entry)
    owner = Owner.of(socket.assigns.current_user)
    owned = Library.list_for_owner(owner)
    owned_chars = Enum.filter(owned, &(&1.kind == "character"))

    # bible_id may be stored as a string (setup) or integer (select_world); normalize
    # so it matches integer entry ids for selection and the world roster filter.
    world_id = normalize_id(payload[:bible_id])
    bibles = selectable_worlds(owner, owned, world_id)

    # The cast references characters by their stable library id — never by name, so a
    # rename can't drop anyone. Names are resolved for display only.
    # Ordered by the campaign's own list, not the library's. Voice colours are
    # assigned by cast order and have to be stable — the same character is the same
    # hue here, in the transcript, and in the status strip — so the order can't come
    # from a query whose result shifts when an unrelated character is created.
    cast_ids = cast_ids(payload)
    by_id = Map.new(owned_chars, &{&1.id, &1})
    cast = Enum.flat_map(cast_ids, fn id -> List.wrap(by_id[id]) end)

    # Characters that can still be added: owned, not already cast, and — when a world
    # is attached — belonging to that world (or unassigned), so the world scopes the
    # roster the way the library filter does.
    addable =
      owned_chars
      |> Enum.reject(&(&1.id in cast_ids))
      |> Enum.filter(&addable_in_world?(&1, world_id))

    assign(socket,
      payload: payload,
      owner: owner,
      cast: cast,
      addable: addable,
      scenes: payload[:scenes] || [],
      bibles: bibles,
      bible_id: world_id,
      bible_name: bible_label(bibles, world_id),
      world: world_payload(bibles, world_id),
      llm: Settings.from_payload(payload),
      global_models: global_models(),
      content: CampaignConfig.from_payload(payload),
      groups: group_rows(owner),
      published?: Library.published?(socket.assigns.entry)
    )
    |> assign_seen()
    |> preflight()
  end

  # A group is made **inside** a campaign, like a world or a character — the library's
  # only create action is a campaign (`LibraryLive`), and two front doors for one thing
  # is how they drift.
  def handle_event("new_group", _params, socket) do
    safe(socket, fn ->
      entry = Groups.create(socket.assigns.owner, %Group{name: "New group"})
      {:noreply, push_navigate(socket, to: ~p"/authoring/group/#{entry.id}")}
    end)
  end

  # Same reasoning as `new_group`, and the same gap it closed: everything under Cast
  # could *add* a character that already existed, and nothing could write one. On a
  # first-run campaign the picker is empty and hidden, so the cast tab offered no way
  # into the character editor at all — Quick Build was the only route to a cast.
  #
  # Written as a **stub**, which is not a judgement about how much they matter (that's
  # `tier`, a separate axis) but the thing that keeps a blank sheet out of a scene:
  # `SceneControl` refuses a non-`:full` character, and the editor flips it on the
  # first save (§B8). So an abandoned one reads as pending instead of standing in the
  # cast with nothing written.
  def handle_event("new_character", _params, socket) do
    safe(socket, fn ->
      entry =
        Library.put(%{
          owner: socket.assigns.owner,
          kind: "character",
          payload: %CharacterSheet{
            name: "New character",
            status: :stub,
            world_bible_id: socket.assigns.bible_id
          }
        })

      # Cast them on the way out. The button is *in* the cast list, so anything else
      # would be a character written from a campaign that isn't in it.
      ids = cast_ids(socket.assigns.payload) ++ [entry.id]
      payload = Map.put(socket.assigns.payload, :character_ids, ids)
      {:ok, _} = Library.update_payload(socket.assigns.entry.id, payload)

      {:noreply, push_navigate(socket, to: ~p"/authoring/character/#{entry.id}")}
    end)
  end

  # The third of the same gap. Worlds could only ever be *picked* from a list the app
  # had no way to add to: nothing anywhere created one, so Quick Build was the only
  # route to a world, and a campaign that skipped it had a dropdown reading "— none —"
  # and no way out of that.
  #
  # Written straight into this campaign rather than into the library and then attached,
  # because a world written *here* is already this campaign's own copy — the copy-on-
  # attach step (§2.5b) exists to stop two campaigns sharing a bible, and there is
  # nothing to copy from. Named blank on purpose: a blank name can't clash, and
  # "Untitled world" reads as unfinished, which it is.
  def handle_event("new_world", _params, socket) do
    safe(socket, fn ->
      entry =
        Library.put(%{
          owner: socket.assigns.owner,
          kind: "world_bible",
          payload: %WorldBible{name: ""}
        })

      payload = Map.put(socket.assigns.payload, :bible_id, entry.id)
      {:ok, _} = Library.update_payload(socket.assigns.entry.id, payload)

      {:noreply, push_navigate(socket, to: ~p"/authoring/bible/#{entry.id}")}
    end)
  end

  def handle_event("set_scene_location", params, socket),
    do:
      {:noreply,
       assign(socket,
         scene_location: params["location"] || socket.assigns.scene_location,
         scene_premise: params["premise"] || socket.assigns.scene_premise
       )}

  # A chip per ready character. The first tap materialises the set from "everyone",
  # so turning one person off doesn't read as turning everyone else off.
  def handle_event("toggle_scene_cast", %{"id" => id}, socket) do
    cid = normalize_id(id)
    current = Screens.Campaign.scene_cast_ids(socket.assigns)

    chosen =
      if MapSet.member?(current, cid),
        do: MapSet.delete(current, cid),
        else: MapSet.put(current, cid)

    {:noreply, assign(socket, scene_cast: chosen)}
  end

  # Where and what's at stake, in one call — see `Autofill.generate_scene_opening/1`
  # for why they aren't two buttons.
  def handle_event("suggest_scene", _params, socket) do
    safe(socket, fn ->
      opts =
        [
          world: scene_world(socket),
          cast: scene_cast_summaries(socket.assigns),
          so_far: scene_lines(socket.assigns),
          current: %{
            "location" => socket.assigns.scene_location,
            "premise" => socket.assigns.scene_premise
          }
        ] ++ meter_attribution(socket)

      {:noreply,
       socket
       |> assign(scene_suggesting: true)
       |> request_generation("scene", "autofill.scene_opening", %{opts: opts})}
    end)
  end

  # There was no clause for this at all. A `phx-click` with nothing to match raises
  # `FunctionClauseError`, which kills the LiveView — so the one control on this screen
  # whose entire job is *explaining* the screen took it down and left a page you could
  # only get out of by reloading.
  # A patch, not a navigate: switching perspective is the same screen looking at the
  # same campaign, which is the one thing a remount would throw away.
  def handle_event("view_as", %{"as" => as}, socket) do
    tab = socket.assigns.tab
    query = if as in [nil, ""], do: [tab: tab], else: [tab: tab, as: as]
    {:noreply, push_patch(socket, to: ~p"/campaigns/#{socket.assigns.entry.id}?#{query}")}
  end

  def handle_event("publish_help", _params, socket),
    do: {:noreply, assign(socket, publish_help: not socket.assigns.publish_help)}

  # Write one pending character in, from the screen where you are choosing a cast.
  #
  # The scene picker only ever offered `:full` characters, because `SceneControl`
  # refuses anything else — correct, and it left the walk-ons a campaign invents for
  # itself unreachable from the one screen where you decide who is in a scene. The
  # cast tab's "generate the pending ones" is a bulk pass on another tab, which is not
  # the same act: here you want *this* person, now, because the scene needs them.
  #
  # Reuses the same `campaign.stubs` op with a list of one — a walk-on written for a
  # scene should be written the same way as one written in a batch, or they read
  # differently in the same story.
  def handle_event("write_in", %{"id" => id}, socket) do
    safe(socket, fn ->
      cid = normalize_id(id)
      uid = socket.assigns.current_user && socket.assigns.current_user.id

      case Enum.find(socket.assigns.cast, &(&1.id == cid and Screens.Campaign.pending?(&1))) do
        nil ->
          {:noreply, put_flash(socket, :error, "They aren't waiting to be written.")}

        entry ->
          {:noreply,
           socket
           |> assign(writing_in: MapSet.put(socket.assigns.writing_in, entry.id))
           |> request_generation("write_in:#{entry.id}", "campaign.stubs", %{
             ids: [entry.id],
             user_id: uid
           })}
      end
    end)
  end

  def handle_event("toggle_quick_build", _params, socket),
    do: {:noreply, assign(socket, quick_build_open: not socket.assigns.quick_build_open)}

  # **Attaching a world copies it** (`completed-roadmap.md` §2.5b). A campaign
  # accumulates world arc, and two campaigns cannot write different histories onto one
  # bible — so what the campaign holds is its own copy, and the library entry stays a
  # template. The honest cost is stated on the screen rather than implied away: fixing
  # a typo in the library copy doesn't fix the campaigns started from it.
  def handle_event("select_world", %{"bible_id" => id}, socket) do
    safe(socket, fn ->
      {bible_id, note} = attach_world(socket, id)
      payload = Map.put(socket.assigns.payload, :bible_id, bible_id)
      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)

      {:noreply, socket |> assign(entry: entry) |> load() |> put_flash(:info, note)}
    end)
  end

  def handle_event("add_character", %{"id" => id}, socket) do
    safe(socket, fn ->
      case normalize_id(id) do
        nil ->
          {:noreply, socket}

        cid ->
          # The picker only ever offers this user's own people, but the id arrives in a
          # form and the cast is what feeds every character's context — an unchecked id
          # here casts a stranger's private sheet into your scenes and renders it back.
          if Permissions.can_edit?(Library.get(cid), socket.assigns.current_user) do
            ids = Enum.uniq(cast_ids(socket.assigns.payload) ++ [cid])
            {:noreply, update_cast(socket, ids, "Added #{display_name(cid)} to the cast.")}
          else
            {:noreply, put_flash(socket, :error, "That character isn't yours to cast.")}
          end
      end
    end)
  end

  # Removing somebody cuts their ties to the rest of the cast, both ways — a
  # relationship is a link between two people who share a story, and leaving a dangling
  # `target_id` behind means the remaining sheets keep describing a person nobody can
  # meet, in their prompts as well as on screen (`Campaigns.uncast/3`).
  def handle_event("remove_character", %{"id" => id}, socket) do
    safe(socket, fn ->
      cid = normalize_id(id)
      name = display_name(cid)
      :ok = Campaigns.uncast(socket.assigns.entry.id, cid)

      {:noreply,
       socket
       |> assign(entry: Library.get(socket.assigns.entry.id))
       |> load()
       |> put_flash(:info, "Removed #{name} from the cast.")}
    end)
  end

  def handle_event("update_details", params, socket) do
    safe(socket, fn ->
      # The screen is tabbed now, so each form carries only its own fields — and a
      # key that isn't in the params must be left alone rather than blanked. The old
      # unconditional `params["name"] || ""` would have wiped the name every time the
      # premise changed.
      payload =
        socket.assigns.payload
        |> put_present(:name, params["name"])
        |> put_present(:premise, params["premise"])
        |> put_tuning(params)

      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)
      {:noreply, socket |> assign(entry: entry) |> load()}
    end)
  end

  # Per-campaign content ceiling (§A5, layer 2). The `adult_content` master gates the
  # three category sub-toggles; with it off the register is empty regardless. This caps
  # every character's categorized boundaries at scene assembly (a disabled category is
  # forced closed) and sets the published content label.
  def handle_event("update_content", params, socket) do
    safe(socket, fn ->
      config = %CampaignConfig{
        adult_content: params["adult_content"] == "true",
        sexual: params["sexual"] == "true",
        graphic_violence: params["graphic_violence"] == "true",
        other: params["other"] == "true"
      }

      payload = Map.put(socket.assigns.payload, :content_config, config)
      {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)
      {:noreply, socket |> assign(entry: entry) |> load()}
    end)
  end

  # ✨ Expand the premise: deepen whatever's saved, grounded in the world + cast.
  # One button, two shapes. With a title already typed this deepens the premise and
  # nothing else; with the title still blank it asks for both at once — the same call
  # Quick Build makes, for the same reason: a title is a *read* on the premise, and
  # asked for on its own it has only the world to go on and hands back the setting's
  # name. An untitled campaign is the common case, and making the author press a
  # second button for the obvious consequence of the first is the kind of step nobody
  # takes.
  def handle_event("expand_premise", _params, socket) do
    safe(socket, fn ->
      current = socket.assigns.payload[:premise] || ""
      context = premise_context(socket) ++ meter_attribution(socket)

      {op, opts} =
        if Screens.Campaign.blank?(socket.assigns.payload[:name]),
          do: {"autofill.campaign_opening", context},
          else: {"autofill.premise", [current: current] ++ context}

      {:noreply,
       socket
       |> assign(expanding_premise: true)
       |> request_generation("premise", op, %{opts: opts})}
    end)
  end

  # Keep the Quick Build form's fields in the socket so add/remove-row re-renders don't
  # drop what's been typed. Blurring an input (phx-debounce="blur") syncs it here.
  def handle_event("sync_quick_build", params, socket) do
    {:noreply,
     assign(socket,
       qb_world: params["world_seed"] || socket.assigns.qb_world,
       qb_seeds: seeds_param(params["char_seed"], socket.assigns.qb_seeds),
       qb_suggest: params["suggest_offscreen"] == "true",
       qb_groups: params["groups"] == "true"
     )}
  end

  def handle_event("add_seed", _params, socket) do
    {:noreply, assign(socket, qb_seeds: socket.assigns.qb_seeds ++ [""])}
  end

  def handle_event("remove_seed", %{"index" => i}, socket) do
    seeds = List.delete_at(socket.assigns.qb_seeds, String.to_integer(i))
    {:noreply, assign(socket, qb_seeds: if(seeds == [], do: [""], else: seeds))}
  end

  # Quick Build: from a world seed and one seed per character, generate a world, a cast,
  # cross-linked relationships and a premise — all persisted, and all associated to this
  # campaign *as they are written* rather than at the end.
  #
  # Enqueued rather than run here. It was a `start_async` linked to this socket, which
  # made a multi-minute, paid, half-persisting job depend on the tab staying open — and
  # an interrupted one left an orphan world under the name the author was about to use
  # (see `Polyphony.Jobs.QuickBuild`). Now the screen starts it and watches it; it does
  # not own it, so closing the tab is not an event the build has to survive.
  def handle_event("quick_build", params, socket) do
    safe(socket, fn ->
      # Every character row becomes a character, even a blank one (it generates freely
      # from the world) — the row count is the cast size the author asked for.
      seeds = params["char_seed"] |> List.wrap() |> Enum.map(&String.trim/1)

      opts =
        [
          owner: socket.assigns.owner,
          world_seed: params["world_seed"] || "",
          character_seeds: seeds,
          suggest_offscreen: params["suggest_offscreen"] == "true",
          groups: params["groups"] == "true",
          campaign_id: socket.assigns.entry.id
        ] ++ meter_attribution(socket)

      case BuildJob.enqueue(opts) do
        {:ok, run} ->
          {:noreply, assign(socket, build: run)}

        :taken ->
          {:noreply,
           socket
           |> assign(build: Builds.get(socket.assigns.entry.id))
           |> put_flash(:info, "A build is already running for this campaign.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Couldn't start the build: #{inspect(reason)}")}
      end
    end)
  end

  # Resume, not restart: the run keeps its `done` list, so this pays only for the world
  # and the characters that aren't written yet.
  def handle_event("retry_build", _params, socket) do
    safe(socket, fn ->
      case BuildJob.retry(socket.assigns.entry.id) do
        {:ok, run} ->
          {:noreply, assign(socket, build: run)}

        :taken ->
          {:noreply, assign(socket, build: Builds.get(socket.assigns.entry.id))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Couldn't start it again: #{inspect(reason)}")}
      end
    end)
  end

  # The author has read the outcome. Dismissing forgets the row rather than hiding it,
  # because the next build needs the campaign unclaimed.
  def handle_event("dismiss_build", _params, socket) do
    Builds.clear(socket.assigns.entry.id)
    {:noreply, socket |> assign(build: nil) |> load()}
  end

  def handle_event("start_scene", _params, socket) do
    safe(socket, fn ->
      %{entry: entry, cast: cast} = socket.assigns
      # Only finalized characters enter the scene; pending stubs are skipped (they
      # aren't castable until generated — bulk-generate them from the library first).
      # Of those, the ones the author picked for *this* scene.
      {_all_ready, pending} = Enum.split_with(cast, &Screens.Campaign.full?/1)
      ready = Screens.Campaign.scene_cast_entries(socket.assigns)

      cond do
        ready == [] ->
          {:noreply,
           put_flash(socket, :error, "No ready characters — generate the pending ones first.")}

        # Arc-review gate (§3.0): no new scene while the cast (or the campaign's world)
        # has unreviewed arc — generation works from the sheet, so open one and the
        # Director writes a character who's fallen behind the story. Accept-all on the
        # review screen is the one-tap way through.
        # Checked by library id — the same identity the cast enters the scene under
        # and arc extraction files proposals against (§5.2).
        match?({:blocked, _}, SceneGate.check(entry.id, Enum.map(ready, & &1.id))) ->
          {:noreply,
           socket
           |> put_flash(:error, "Review the pending arc changes before the next scene.")
           |> redirect(to: ~p"/arc/#{entry.id}")}

        true ->
          start_scene(socket, ready, pending)
      end
    end)
  end

  def handle_event("toggle_spectator", _params, socket),
    do:
      {:noreply, socket |> assign(pub_spectator: not socket.assigns.pub_spectator) |> preflight()}

  def handle_event("toggle_forkable", _params, socket),
    do: {:noreply, assign(socket, pub_forkable: not socket.assigns.pub_forkable)}

  def handle_event("toggle_perspective", %{"id" => id}, socket) do
    id = to_string(id)
    current = socket.assigns.pub_perspectives

    next = if id in current, do: List.delete(current, id), else: current ++ [id]

    {:noreply, socket |> assign(pub_perspectives: next) |> preflight()}
  end

  # ── Archive, trash, restart ──────────────────────────────────────────────────
  #
  # The three ways a campaign ends, and they are genuinely different things rather
  # than one control with a severity dial. They live here rather than only on the
  # library row because this is the screen you are on when you decide — and two of
  # them had no reachable control at all from inside a campaign.

  def handle_event("archive_campaign", _params, socket) do
    owned(socket, fn ->
      {:ok, _} = Library.archive(socket.assigns.entry.id)
      {:noreply, push_navigate(socket, to: ~p"/library?tab=shelves")}
    end)
  end

  def handle_event("trash_campaign", _params, socket) do
    owned(socket, fn ->
      {:ok, _} = Library.soft_delete(socket.assigns.entry.id)
      {:noreply, push_navigate(socket, to: ~p"/library?tab=shelves")}
    end)
  end

  # Not "delete the scenes". The arc queue goes with them, and that is the point: a
  # proposal about something that never happened is a review item you cannot answer.
  def handle_event("restart_campaign", _params, socket) do
    owned(socket, fn ->
      {:ok, %{scenes: n, rows: rows}} = Campaigns.restart(socket.assigns.entry.id)
      arcs = Map.get(rows, "arc_entries", 0)

      {:noreply,
       socket
       |> assign(entry: Library.get(socket.assigns.entry.id))
       |> put_flash(:info, restart_note(n, arcs))
       |> load()}
    end)
  end

  def handle_event("publish", _params, socket) do
    safe(socket, fn ->
      %{entry: entry, payload: payload, cast: cast, owner: owner} = socket.assigns
      bible = if payload[:bible_id], do: Library.get(payload[:bible_id]) |> maybe_payload()

      characters =
        Enum.map(cast, fn c ->
          %{source_id: c.id, source_version: c.version, sheet: Library.payload(c)}
        end)

      result =
        Library.publish_campaign(
          %{
            owner: owner,
            campaign_id: entry.id,
            published_beat: 0,
            bible: bible,
            characters: characters,
            arc: [],
            content: CampaignConfig.from_payload(payload),
            # The grant travels with the published copy, since that's the thing readers
            # hold — and it is replaced wholesale on a republish, so narrowing it here
            # narrows it for everyone reading.
            publication: publication(socket),
            scenes: Preflight.scenes(socket.assigns.scenes)
          },
          visibility: "public"
        )

      case result do
        {:error, :hidden} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "This one was taken down. Publishing again isn't the way to appeal it."
           )}

        _ ->
          {:noreply, socket |> put_flash(:info, publish_note(socket)) |> load()}
      end
    end)
  end

  # Fill every pending stub at once — ground each one's sheet in its world and role and
  # finalize it, so the author doesn't open twenty walk-ons one by one. This lives on
  # the cast rather than in the library because characters are written *inside* a
  # campaign now (`ux/polyphony-library.html` §00): the pending ones are the campaign's
  # pending ones, and the button belongs next to the pills that say so.
  def handle_event("generate_pending", _params, socket) do
    safe(socket, fn ->
      case Enum.filter(socket.assigns.cast, &Screens.Campaign.pending?/1) do
        [] ->
          {:noreply, socket}

        stubs ->
          uid = socket.assigns.current_user && socket.assigns.current_user.id

          {:noreply,
           socket
           |> assign(generating: true)
           |> request_generation("stubs", "campaign.stubs", %{
             ids: Enum.map(stubs, & &1.id),
             user_id: uid
           })}
      end
    end)
  end

  # Written in, and **selected**: you pressed this while choosing who is in a scene, so
  # the only reason to write them was to use them. Adding them to the selection saves
  # the step, and `scene_cast_ids/1` intersects with who is currently ready, so this is
  # the moment they become eligible at all.
  def handle_info({:generation, "write_in:" <> id, {:ok, {done, _failed}}}, socket) do
    cid = normalize_id(id)

    socket =
      socket
      |> forget_generation("write_in:#{id}")
      |> assign(
        writing_in: MapSet.delete(socket.assigns.writing_in, cid),
        entry: Library.get(socket.assigns.entry.id)
      )
      |> load()

    if done > 0 do
      chosen = MapSet.put(Screens.Campaign.scene_cast_ids(socket.assigns), cid)
      {:noreply, assign(socket, scene_cast: chosen)}
    else
      {:noreply, put_flash(socket, :error, "Couldn't write them — open them to finish by hand.")}
    end
  end

  def handle_info({:generation, "write_in:" <> id, result}, socket) do
    Logger.warning("[campaign] write-in failed for #{id}: #{inspect(result)}")

    {:noreply,
     socket
     |> forget_generation("write_in:#{id}")
     |> assign(writing_in: MapSet.delete(socket.assigns.writing_in, normalize_id(id)))
     |> put_flash(:error, "Couldn't write them — open them to finish by hand.")}
  end

  def handle_info({:generation, "stubs", {:ok, {done, failed}}}, socket) do
    detail = if failed > 0, do: " #{failed} failed — open those to retry.", else: ""

    {:noreply,
     socket
     |> forget_generation("stubs")
     |> assign(generating: false, entry: Library.get(socket.assigns.entry.id))
     |> put_flash(:info, "Generated #{done} character(s).#{detail}")
     |> load()}
  end

  def handle_info({:generation, "scene", {:ok, %{"location" => l, "premise" => p}}}, socket) do
    {:noreply,
     socket
     |> forget_generation("scene")
     |> assign(
       scene_suggesting: false,
       scene_location: blank_to(l, socket.assigns.scene_location),
       scene_premise: blank_to(p, socket.assigns.scene_premise)
     )}
  end

  def handle_info({:generation, "scene", result}, socket) do
    Logger.warning("[campaign] scene opening failed: #{inspect(result)}")

    {:noreply,
     socket
     |> forget_generation("scene")
     |> assign(scene_suggesting: false)
     |> put_flash(:error, "Couldn't suggest a scene: #{inspect(reason(result))}")}
  end

  # A map when the campaign had no title, a string when it did. The name is only ever
  # written into a blank — the same rule Quick Build follows, and for the same reason.
  def handle_info({:generation, "premise", {:ok, %{"premise" => text} = data}}, socket) do
    payload = socket.assigns.payload

    payload =
      if Screens.Campaign.blank?(payload[:name]) and not Screens.Campaign.blank?(data["name"]),
        do: Map.put(payload, :name, data["name"]),
        else: payload

    {:noreply, apply_premise(socket, payload, text)}
  end

  def handle_info({:generation, "premise", {:ok, text}}, socket),
    do: {:noreply, apply_premise(socket, socket.assigns.payload, text)}

  def handle_info({:generation, "stubs", result}, socket) do
    Logger.warning("[authoring] bulk stub generation failed: #{inspect(result)}")

    {:noreply,
     socket
     |> forget_generation("stubs")
     |> assign(generating: false)
     |> put_flash(:error, "Bulk generation failed — try again.")}
  end

  def handle_info({:generation, "premise", result}, socket) do
    Logger.warning("[campaign] premise generation failed: #{inspect(result)}")

    {:noreply,
     socket
     |> forget_generation("premise")
     |> assign(expanding_premise: false)
     |> put_flash(:error, "Premise generation failed: #{inspect(reason(result))}")}
  end

  # Progress from the build job, over PubSub. The row is the truth and this is only the
  # fast path — anything missed while disconnected is picked up by the read in `mount`,
  # which is what makes coming back to a running build work at all.
  def handle_info({:build_progress, %BuildRun{} = run}, socket) do
    socket = assign(socket, build: run)

    # Re-read the *entry*, not just the derived assigns: the job writes the world, the
    # cast and the premise onto the campaign row, and `load/1` projects from the entry
    # struct the socket is holding. Without this the screen renders a campaign frozen at
    # the moment it was opened while the database has the built one.
    socket = assign(socket, entry: Library.get(socket.assigns.entry.id) || socket.assigns.entry)

    {:noreply,
     if run.status == "done" do
       # Clear the form only on success. A failed build leaves it up, because the next
       # move is to change a seed and go again — and taking it away would leave the
       # author looking at the card that opens it.
       socket
       |> assign(
         quick_build_open: false,
         qb_world: "",
         qb_seeds: [""],
         qb_suggest: true,
         qb_groups: false
       )
       |> load()
     else
       load(socket)
     end}
  end

  def handle_info({:build_cleared, _campaign_id}, socket),
    do: {:noreply, assign(socket, build: nil)}

  # Open the scene for the ready cast (the arc-review gate has passed).
  defp start_scene(socket, ready, pending) do
    %{entry: entry, payload: payload} = socket.assigns

    scene_id = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
    # The scene's own premise, falling back to the campaign's. Every scene used to open
    # on the campaign pitch, which describes the whole story and nothing about now.
    premise = blank_to(socket.assigns.scene_premise, payload[:premise] || "")
    bible = payload[:bible_id] && Library.get(payload[:bible_id]) |> maybe_payload()

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene_id,
        campaign_id: entry.id,
        location_id: blank_to_nil(socket.assigns.scene_location),
        premise: premise,
        opened_beat: 0
      })

    sheets = Enum.map(ready, &Library.payload/1)
    content_config = CampaignConfig.from_payload(payload)

    # Characters enter by their **library id**, not their name (§5.2). The id is what
    # the log, membership, packet ids, whisper routing and arc all key on from here;
    # the name is a display field the prompt boundary renders back (Scene.Cast). This
    # is the mint — get it wrong here and a rename corrupts the scene later.
    for {c, sheet} <- Enum.zip(ready, sheets) do
      character_id = to_string(c.id)
      :ok = App.dispatch(%EnterCharacter{scene_id: scene_id, character_id: character_id, beat: 1})
      seed_context(scene_id, character_id, sheet, premise, bible, content_config)
    end

    # The Director's omniscient brief: the world, the premise, the whole cast, and
    # the cross-scene omniscient summaries (pgvector — no-ops without egress). The
    # Director is omniscient, so it folds in ALL canon world arc (§2.8).
    SceneBrief.materialize(scene_id,
      world_bible: Effective.world_bible(bible, entry.id, :all),
      premise: premise,
      roster: sheets,
      retriever: PgvectorRetriever
    )

    Library.update_payload(entry.id, %{payload | scenes: [scene_id | socket.assigns.scenes]})

    {:noreply,
     socket
     |> assign(scene_location: "", scene_premise: "", scene_cast: nil)
     |> maybe_flash_pending(pending)
     |> redirect(to: ~p"/play/#{scene_id}")}
  end

  defp seed_context(
         scene_id,
         character_id,
         %CharacterSheet{} = sheet,
         premise,
         bible,
         content_config
       ) do
    {campaign_id, location} = scene_campaign_location(scene_id)

    ctx =
      Context.materialize(
        scene_id: scene_id,
        character_id: character_id,
        # Canon character + world arc folded in (§2.8), scoped to this scene's location.
        # Arc is keyed by the same id the log uses, so it survives a rename too.
        sheet: Effective.sheet(sheet, character_id),
        premise: premise,
        world_bible: Effective.world_bible(bible, campaign_id, location),
        # The campaign content ceiling (§A5): caps this character's categorized
        # boundaries and renders the enabled register into their frozen prefix.
        content_config: content_config,
        # Retrieve this character's own distant-scene summaries from pgvector
        # (no-ops to [] without egress / when the embed fails).
        retriever: PgvectorRetriever
      )

    Store.put(scene_id, character_id, ctx)
  end

  defp seed_context(_scene_id, _character_id, _other, _premise, _bible, _content_config),
    do: :ok

  # The scene's campaign + authored location, from its opening event (durable) — for
  # folding canon world arc into the world half of context, scoped to this place.
  defp scene_campaign_location(scene_id) do
    case Rebuild.opened(scene_id) do
      %SceneOpened{campaign_id: c, location_id: l} -> {c, l}
      _ -> {nil, nil}
    end
  end

  defp maybe_payload(nil), do: nil
  defp maybe_payload(entry), do: Library.payload(entry)

  defp parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp blank_to_nil(value) do
    case String.trim(to_string(value || "")) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # The deployment's global default models, shown as placeholders so an author can see
  # what a campaign falls back to when its model fields are left blank.
  defp global_models do
    llm = Application.get_env(:polyphony, :llm, [])
    workhorse = get_in(llm, [:deepinfra, :model]) || get_in(llm, [:models, :workhorse])
    %{workhorse: workhorse, heavy: get_in(llm, [:models, :heavy])}
  end

  # Grounding for premise generation: the attached world (as the editor display map)
  # and the cast's names + one-line premises.
  defp premise_context(socket) do
    world =
      case socket.assigns.bible_id && Library.get(socket.assigns.bible_id) do
        %{} = entry -> world_display(Library.payload(entry))
        _ -> nil
      end

    cast =
      for c <- socket.assigns.cast do
        s = Library.payload(c)
        %{"name" => Screens.Campaign.char_name(c), "premise" => Map.get(s, :premise)}
      end

    [world: world, cast: cast]
  end

  defp world_display(wb) do
    %{
      "name" => Map.get(wb, :name) || "",
      "setting" => Map.get(wb, :setting) || "",
      "tone" => Map.get(wb, :tone) || "",
      # Both list fields go through `public/1`, and both have to. They are lists of
      # `WorldBible.Entry` structs, not strings — joining the raw list raises
      # `String.Chars`, which is how this was found: every ✦ on this screen that
      # grounds itself in the world (the premise, the scene opening) died on any bible
      # with a rule in it. And a concealed rule is a secret law of the world, so the
      # character-facing read is also the correct one, not merely the one that compiles.
      "rules" => Enum.join(WorldBible.public(Map.get(wb, :rules) || []), "\n"),
      "starting_canon" => Enum.join(WorldBible.public(Map.get(wb, :starting_canon) || []), "\n")
    }
  end

  # Usage attribution for a metered generation call (provider defaults in Autofill).
  defp meter_attribution(socket) do
    case socket.assigns.current_user do
      %{id: id} -> [user_id: id]
      _ -> []
    end
  end

  defp reason({:ok, {:error, r}}), do: r
  defp reason({:exit, r}), do: r
  defp reason(other), do: other

  # The `char_seed[]` params: a list when several rows exist, a bare string for one,
  # nil when the form omitted them (a change from another field) — fall back then.
  defp seeds_param(list, _fallback) when is_list(list), do: list
  defp seeds_param(str, _fallback) when is_binary(str), do: [str]
  defp seeds_param(_, fallback), do: fallback

  defp put_present(payload, _key, nil), do: payload
  defp put_present(payload, key, value), do: Map.put(payload, key, value)

  # Model tuning lives on one form; presence is detected on a field that always
  # submits (a checkbox sends nothing when unchecked, so `director_thinking` can't
  # be the signal).
  defp put_tuning(payload, params) do
    if Map.has_key?(params, "director_max_tokens") do
      defaults = Settings.defaults()

      Map.put(payload, :llm, %{
        director_thinking: params["director_thinking"] == "true",
        director_max_tokens:
          parse_int(params["director_max_tokens"], defaults.director_max_tokens),
        character_max_tokens:
          parse_int(params["character_max_tokens"], defaults.character_max_tokens),
        # Blank ⇒ nil ⇒ the deployment's global default model (DEEPINFRA_MODEL / heavy).
        model: blank_to_nil(params["model"]),
        heavy_model: blank_to_nil(params["heavy_model"]),
        # DeepInfra scheduling tier; Settings coerces an unknown value back to nil.
        service_tier: blank_to_nil(params["service_tier"])
      })
    else
      payload
    end
  end

  # ── Render ─────────────────────────────────────────────────────────────────────
  #
  # Ported from `ux/polyphony-campaign.html`. The screen became **tabbed**: one long
  # scroll of every setting was the thing the design pass changed most here, because
  # the campaign is the hub and almost none of it is needed at once.
  #
  # Two of the mock's decisions are load-bearing. **Quick Build isn't a tab** — it's
  # a one-shot that's dead weight from day two, so it appears as a first-run card and
  # otherwise stays folded away. And **Premise comes after Cast**, because the pitch
  # is written *from* the cast; ordering it earlier invites writing it twice.

  # With no world attached, every owned character is addable; with one attached, the
  # roster is scoped to that world's characters plus any not yet assigned to a world.
  defp addable_in_world?(_char, nil), do: true

  defp addable_in_world?(char, world_id) do
    wid = char |> Library.payload() |> Map.get(:world_bible_id)
    wid in [nil, world_id]
  end

  # Generation on this screen is two independent buttons with a boolean each, rather
  # than the editors' set of in-flight keys, so it talks to `Generations` directly. The
  # durability is the same and the reason is the same: expanding a premise takes seconds,
  # and the answer must not belong to whichever tab happened to ask.
  defp apply_premise(socket, payload, text) do
    payload = Map.put(payload, :premise, text)
    {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)

    socket
    |> forget_generation("premise")
    |> assign(entry: entry, expanding_premise: false)
    |> load()
  end

  defp attach_world(_socket, ""), do: {nil, "World removed."}

  defp attach_world(socket, id) do
    source = Library.get(String.to_integer(id))

    cond do
      is_nil(source) ->
        {nil, "That world is gone."}

      # Attaching *copies*, so an unchecked id is a way to take a private bible —
      # secrets included — out of somebody else's library. Taking a published world is
      # a real flow, but it belongs to Browse, which strips what was kept back
      # (`WorldBible.stripped/1`); this path would copy it whole.
      not Permissions.can_edit?(source, socket.assigns.current_user) ->
        {socket.assigns.payload[:bible_id], "That world isn't yours to attach."}

      # Already this campaign's own copy — re-selecting it must not copy the copy.
      source.id == socket.assigns.payload[:bible_id] ->
        {source.id, "World updated."}

      true ->
        copy = Library.copy(source, socket.assigns.current_user)
        {copy.id, "This campaign has its own copy of #{world_name(source)} now."}
    end
  end

  defp bible_label(_bibles, nil), do: nil

  defp bible_label(bibles, id) do
    case Enum.find(bibles, &(&1.id == id)) do
      nil -> nil
      entry -> Screens.Campaign.bible_label_of(entry)
    end
  end

  defp blank_to(value, fallback) do
    case String.trim(to_string(value || "")) do
      "" -> fallback
      text -> text
    end
  end

  # A view of the row, not a flag of its own — `building?` is only ever asked of what
  # the database says, so a socket that reconnects mid-build gets the right answer.

  # The cast as a list of integer library ids (tolerating any legacy name entries,
  # which simply won't resolve to a character and drop out).
  defp cast_ids(payload) do
    (payload[:character_ids] || []) |> Enum.map(&normalize_id/1) |> Enum.reject(&is_nil/1)
  end

  defp display_name(nil), do: "character"

  defp display_name(id) do
    case Library.get(id) do
      nil -> "character"
      entry -> Screens.Campaign.char_name(entry)
    end
  end

  # Applying a result consumes it, so a live delivery can't be replayed on the next mount.
  defp forget_generation(socket, key) do
    Generations.forget(socket.assigns.entry.id, key)
    socket
  end

  # A reconnect can't see either of those booleans, so they come back from the rows —
  # and anything that finished while the page was closed is re-delivered as the ordinary
  # message the handlers below already take.

  defp group_name(_entry, %{name: n}) when is_binary(n) and n != "", do: n

  defp group_name(entry, _group), do: "Unnamed group (##{entry.id})"

  # Groups sit beside Cast because that is where they are used (§06b): a group is
  # written like a character and used as a starting point for others.
  defp group_rows(owner) do
    for entry <- Groups.list(owner) do
      group = Library.payload(entry)

      %{
        id: entry.id,
        name: group_name(entry, group),
        members: length(group.member_ids || []),
        secrets: length(Group.secrets(group)),
        colour: Voice.of_sheet(group)
      }
    end
  end

  defp maybe_flash_pending(socket, []), do: socket

  defp maybe_flash_pending(socket, pending),
    do:
      put_flash(
        socket,
        :info,
        "Skipped #{length(pending)} pending character(s) — generate them, then re-add to a scene."
      )

  defp normalize_id(nil), do: nil

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  # Owner-only, and refused rather than silently ignored: these three are the
  # irreversible-ish ones, and `Permissions.can_edit?` is the same gate the editors use.
  defp owned(socket, fun) do
    safe(socket, fn ->
      if Permissions.can_edit?(socket.assigns.entry, socket.assigns.current_user) do
        fun.()
      else
        {:noreply, put_flash(socket, :error, "Not found.")}
      end
    end)
  end

  # Recomputed whenever the grant changes, so the warning tracks what's actually ticked
  # rather than appearing once at the end. Only the reading half matters — forkable
  # can't make a scene unreachable.
  defp preflight(socket) do
    scenes = Preflight.scenes(socket.assigns.scenes)
    assign(socket, publish_warning: Preflight.warning(publication(socket), scenes))
  end

  defp publication(socket) do
    %Publication{
      perspectives: socket.assigns.pub_perspectives,
      spectator: socket.assigns.pub_spectator,
      forkable: socket.assigns.pub_forkable
    }
  end

  # Said before and after, because it's the surprising half: there is one published
  # copy, and this replaces it — including for anyone partway through reading it.
  # The load-time assign, not a fresh read: by the time this runs the publish has
  # happened, so asking the database would always say "updated".
  defp publish_note(socket) do
    if socket.assigns.published?,
      do: "Updated the published copy. Anyone reading it gets this version.",
      else: "Published. Anyone with the link reads this."
  end

  defp request_generation(socket, key, op, request) do
    Generations.request(socket.assigns.entry.id, key, op, request)
    socket
  end

  defp restart_note(0, _arcs), do: "Nothing had been played yet."

  defp restart_note(scenes, arcs) do
    "Back to the start — #{Screens.Campaign.count_label(scenes, "scene", "scenes")} let go of" <>
      if(arcs > 0,
        do:
          ", and #{Screens.Campaign.count_label(arcs, "arc proposal", "arc proposals")} with them.",
        else: "."
      )
  end

  defp restore_generations(socket, entry) do
    if connected?(socket) do
      Generations.subscribe(entry.id)
      running = Generations.running(entry.id)

      for {key, result} <- Generations.take(entry.id),
          do: send(self(), {:generation, key, result})

      assign(socket,
        expanding_premise: "premise" in running,
        generating: "stubs" in running,
        scene_suggesting: "scene" in running
      )
    else
      socket
    end
  end

  defp scene_cast_summaries(assigns) do
    for e <- Screens.Campaign.scene_cast_entries(assigns) do
      sheet = Library.payload(e)
      %{"name" => Map.get(sheet, :name), "premise" => Map.get(sheet, :premise)}
    end
  end

  # `world_display/1` filters `starting_canon` through `WorldBible.public/1`, which
  # matters here: a scene premise is read by every character in the scene, so a secret
  # that reached it would be a leak with no symptom but a character who mysteriously
  # knows something.

  # The scenes already played, for "don't open on the same quay again".
  defp scene_lines(assigns),
    do: Enum.map(Enum.reverse(assigns.scenes), &Screens.Campaign.scene_label/1)

  defp scene_world(socket) do
    case socket.assigns.bible_id && Library.get(socket.assigns.bible_id) do
      %{} = entry -> world_display(Library.payload(entry))
      _ -> nil
    end
  end

  # What this campaign may attach: the **templates**, plus its own copy.
  #
  # Attaching copies (§2.5b), so every campaign's working copy lives in the same
  # library under the same name as the thing it came from. The library's Worlds tab has
  # always filtered those out; this picker never did, so a second campaign offered
  # "Saltmarch" twice with nothing to tell them apart — and picking the wrong one takes
  # a copy of another campaign's *played* world, arc and all.
  #
  # The reason this reads as a trash bug is the second line. The attached set has to be
  # computed over campaigns **including the deleted and archived ones**, because a
  # trashed campaign is invisible to `list_for_owner` while its copy is not: the copy
  # stops looking attached the moment its campaign goes in the bin, and reappears here
  # as a template. Filing or binning a campaign is exactly when its world should stop
  # being offered, not when it starts.
  defp selectable_worlds(owner, owned, world_id) do
    all = Library.list_for_owner(owner, include_deleted: true, include_archived: true)

    attached =
      for entry <- all,
          Campaigns.campaign?(entry),
          id = normalize_id(Map.get(Library.payload(entry) || %{}, :bible_id)),
          id != world_id,
          into: MapSet.new(),
          do: id

    for e <- owned, e.kind == "world_bible", not MapSet.member?(attached, e.id), do: e
  end

  # Only the live socket subscribes: the first (static) mount has no process to keep.
  defp subscribe_build(socket, entry) do
    if connected?(socket), do: Builds.subscribe(entry.id)
    socket
  end

  defp update_cast(socket, ids, flash) do
    payload = Map.put(socket.assigns.payload, :character_ids, ids)
    {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)
    socket |> assign(entry: entry) |> load() |> put_flash(:info, flash)
  end

  defp world_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "that world"
    end
  end

  defp world_payload(_bibles, nil), do: nil

  defp world_payload(bibles, id) do
    # Explicitly `nil` on anything that isn't a bible. A bare `with` would hand back
    # the unmatched payload, and the template would then read `.setting` off it.
    case Enum.find(bibles, &(&1.id == id)) do
      nil ->
        nil

      entry ->
        case Library.payload(entry) do
          %WorldBible{} = bible -> bible
          _ -> nil
        end
    end
  end

  # Publishing asks **two separate questions, not one ladder** (§3.1c): how it's meant
  # to be read — which perspectives a reader may adopt, a content decision and the
  # spoiler control — and whether the authoring surface is exposed, which is one
  # checkbox. Sheets come with forkable, because a fork must be able to carry the story
  # on and can't from prose alone.

  def render(assigns) do
    ~H"""
    <Screens.Campaign.screen
      addable={@addable}
      bible_id={@bible_id}
      bible_name={@bible_name}
      bibles={@bibles}
      build={@build}
      cast={@cast}
      content={@content}
      current_user={@current_user}
      entry={@entry}
      expanding_premise={@expanding_premise}
      generating={@generating}
      global_models={@global_models}
      groups={@groups}
      llm={@llm}
      payload={@payload}
      pub_forkable={@pub_forkable}
      pub_perspectives={@pub_perspectives}
      pub_spectator={@pub_spectator}
      publish_help={@publish_help}
      publish_warning={@publish_warning}
      published?={@published?}
      qb_groups={@qb_groups}
      qb_seeds={@qb_seeds}
      qb_suggest={@qb_suggest}
      qb_world={@qb_world}
      quick_build_open={@quick_build_open}
      scene_cast={@scene_cast}
      scene_location={@scene_location}
      scene_premise={@scene_premise}
      scene_suggesting={@scene_suggesting}
      scenes={@scenes}
      seen={@seen}
      tab={@tab}
      viewer={@viewer}
      world={@world}
      writing_in={@writing_in}
    />
    """
  end
end
