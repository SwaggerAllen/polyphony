defmodule PolyphonyWeb.CampaignLive do
  @moduledoc """
  Campaign overview: the cast, the scenes, and the levers to start a scene or publish.
  Starting a scene opens the event-sourced stream, enters the cast, and seeds each
  character's frozen context so the Director loop can run.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias Polyphony.{Library, Owner, Context, App}
  alias Polyphony.Context.{Store, PgvectorRetriever, Rebuild}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  alias Polyphony.Authoring.{
    Autofill,
    CharacterSheet,
    QuickBuild,
    Effective,
    SceneGate,
    StubGen,
    WorldBible
  }

  alias Polyphony.Authoring.Group
  alias Polyphony.Events.SceneOpened
  alias Polyphony.Groups
  alias Polyphony.Campaigns
  alias Polyphony.Content.CampaignConfig
  alias Polyphony.Publication
  alias Polyphony.Publication.Preflight
  alias PolyphonyWeb.Kit
  alias PolyphonyWeb.Layouts
  alias PolyphonyWeb.Voice

  # The campaign's sections, in the design's order. Premise sits after Cast because
  # the pitch is written *from* the cast (`ux/README.md`), and Quick Build is
  # deliberately absent — it's a one-shot card, not a section.
  @tabs [
    {"settings", "Settings"},
    {"world", "World"},
    {"cast", "Cast"},
    {"premise", "Premise"},
    {"scenes", "Scenes"}
  ]

  @doc false
  def tabs, do: @tabs
  alias Polyphony.Director.SceneBrief
  alias Polyphony.LLM.Settings

  def mount(%{"id" => id}, _session, socket) do
    entry = Library.get(id)

    # A frozen snapshot shares the `"campaign"` kind and nothing else — opening the
    # editor on one would try to read a cast and a premise off a `Library.Snapshot`.
    # It's a readable thing, so it goes where reading happens. A taken-down one is
    # gone, and says so in its own words.
    if entry && Campaigns.campaign?(entry) && not Library.hidden?(entry) do
      {:ok,
       socket
       |> assign(
         page_title: "Campaign",
         entry: entry,
         building: false,
         build_progress: nil,
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
         quick_build_open: false,
         scene_location: "",
         tab: "settings"
       )
       |> load()}
    else
      redirect_missing(socket, entry)
    end
  end

  # A take-down removes the thing, not its listing — so this is the deleted experience
  # with the one difference that matters: they're told why, and where the rest of it is.
  defp redirect_missing(socket, %{hidden_at: at} = _entry) when not is_nil(at),
    do:
      {:ok,
       socket
       |> put_flash(:error, "That was taken down after a report. Check your email.")
       |> redirect(to: ~p"/library")}

  defp redirect_missing(socket, %{frozen: true} = entry),
    do:
      {:ok,
       socket
       |> put_flash(:info, "That's a published copy — here's how it reads.")
       |> redirect(to: ~p"/browse?#{[story: entry.id]}")}

  defp redirect_missing(socket, _entry),
    do: {:ok, socket |> put_flash(:error, "Campaign not found.") |> redirect(to: ~p"/library")}

  # The tab lives in the URL, so it's linkable, survives a reload, and back works
  # between sections of a screen that used to be one long scroll.
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, tab: tab_param(params["tab"]))}
  end

  defp tab_param(tab) do
    if Enum.any?(@tabs, fn {slug, _} -> slug == tab end), do: tab, else: "settings"
  end

  defp load(socket) do
    payload = Library.payload(socket.assigns.entry)
    owner = Owner.of(socket.assigns.current_user)
    owned = Library.list_for_owner(owner)
    owned_chars = Enum.filter(owned, &(&1.kind == "character"))
    bibles = Enum.filter(owned, &(&1.kind == "world_bible"))

    # bible_id may be stored as a string (setup) or integer (select_world); normalize
    # so it matches integer entry ids for selection and the world roster filter.
    world_id = normalize_id(payload[:bible_id])

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

  def handle_event("set_scene_location", %{"location" => where}, socket),
    do: {:noreply, assign(socket, scene_location: where)}

  def handle_event("toggle_quick_build", _params, socket),
    do: {:noreply, assign(socket, quick_build_open: not socket.assigns.quick_build_open)}

  # **Attaching a world copies it** (`backend-backlog.md` §2.5b). A campaign
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
          ids = Enum.uniq(cast_ids(socket.assigns.payload) ++ [cid])
          {:noreply, update_cast(socket, ids, "Added #{display_name(cid)} to the cast.")}
      end
    end)
  end

  def handle_event("remove_character", %{"id" => id}, socket) do
    safe(socket, fn ->
      cid = normalize_id(id)
      ids = Enum.reject(cast_ids(socket.assigns.payload), &(&1 == cid))
      {:noreply, update_cast(socket, ids, "Removed #{display_name(cid)} from the cast.")}
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
  def handle_event("expand_premise", _params, socket) do
    safe(socket, fn ->
      opts =
        [current: socket.assigns.payload[:premise] || ""] ++
          premise_context(socket) ++ meter_attribution(socket)

      {:noreply,
       socket
       |> assign(expanding_premise: true)
       |> start_async(:premise, fn -> Autofill.generate_campaign_premise(opts) end)}
    end)
  end

  # Keep the Quick Build form's fields in the socket so add/remove-row re-renders don't
  # drop what's been typed. Blurring an input (phx-debounce="blur") syncs it here.
  def handle_event("sync_quick_build", params, socket) do
    {:noreply,
     assign(socket,
       qb_world: params["world_seed"] || socket.assigns.qb_world,
       qb_seeds: seeds_param(params["char_seed"], socket.assigns.qb_seeds),
       qb_suggest: params["suggest_offscreen"] == "true"
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
  # cross-linked relationships, and a premise — all persisted — then attach them here.
  def handle_event("quick_build", params, socket) do
    safe(socket, fn ->
      # Every character row becomes a character, even a blank one (it generates freely
      # from the world) — the row count is the cast size the author asked for.
      seeds = params["char_seed"] |> List.wrap() |> Enum.map(&String.trim/1)

      lv = self()

      opts =
        [
          owner: socket.assigns.owner,
          world_seed: params["world_seed"] || "",
          character_seeds: seeds,
          suggest_offscreen: params["suggest_offscreen"] == "true",
          campaign_id: socket.assigns.entry.id,
          # The build runs in the async task; forward each phase to this LiveView.
          progress: fn step -> send(lv, {:quick_build_progress, step}) end
        ] ++ meter_attribution(socket)

      {:noreply,
       socket
       |> assign(
         building: true,
         build_progress: %{done: 0, total: length(seeds) + 3, label: "Starting"}
       )
       |> start_async(:quick_build, fn -> QuickBuild.build(opts) end)}
    end)
  end

  def handle_event("start_scene", _params, socket) do
    safe(socket, fn ->
      %{entry: entry, cast: cast} = socket.assigns
      # Only finalized characters enter the scene; pending stubs are skipped (they
      # aren't castable until generated — bulk-generate them from the library first).
      {ready, pending} = Enum.split_with(cast, &full?/1)

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
      case Enum.filter(socket.assigns.cast, &pending?/1) do
        [] ->
          {:noreply, socket}

        stubs ->
          user = socket.assigns.current_user

          {:noreply,
           socket
           |> assign(generating: true)
           |> start_async(:generate_pending, fn -> generate_stubs(stubs, user) end)}
      end
    end)
  end

  def handle_async(:generate_pending, {:ok, {done, failed}}, socket) do
    detail = if failed > 0, do: " #{failed} failed — open those to retry.", else: ""

    {:noreply,
     socket
     |> assign(generating: false, entry: Library.get(socket.assigns.entry.id))
     |> put_flash(:info, "Generated #{done} character(s).#{detail}")
     |> load()}
  end

  def handle_async(:generate_pending, result, socket) do
    Logger.warning("[authoring] bulk stub generation failed: #{inspect(result)}")

    {:noreply,
     socket
     |> assign(generating: false)
     |> put_flash(:error, "Bulk generation failed — try again.")}
  end

  def handle_async(:premise, {:ok, {:ok, text}}, socket) do
    payload = Map.put(socket.assigns.payload, :premise, text)
    {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)

    {:noreply, socket |> assign(entry: entry, expanding_premise: false) |> load()}
  end

  def handle_async(:premise, result, socket) do
    Logger.warning("[campaign] premise generation failed: #{inspect(result)}")

    {:noreply,
     socket
     |> assign(expanding_premise: false)
     |> put_flash(:error, "Premise generation failed: #{inspect(reason(result))}")}
  end

  def handle_async(:quick_build, {:ok, {:ok, result}}, socket) do
    %{bible: bible, characters: chars, premise: premise} = result
    failed = Map.get(result, :failed, [])
    existing = cast_ids(socket.assigns.payload)
    ids = Enum.uniq(existing ++ Enum.map(chars, & &1.id))

    payload =
      socket.assigns.payload
      |> Map.put(:bible_id, bible.id)
      |> Map.put(:character_ids, ids)
      |> Map.put(:premise, premise)

    {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)

    socket =
      socket
      |> assign(
        entry: entry,
        building: false,
        build_progress: nil,
        # Closed as well as emptied. The render guard covers this too, but a flag left
        # true is a form that springs open the moment a campaign is emptied back to
        # first-run, which is not something anyone asked for.
        quick_build_open: false,
        qb_world: "",
        qb_seeds: [""],
        qb_suggest: true
      )
      |> load()
      |> put_flash(
        :info,
        "Built a world, #{length(chars)} character(s), and a premise. Open each to flesh it out."
      )

    {:noreply, flash_failures(socket, failed)}
  end

  def handle_async(:quick_build, result, socket) do
    Logger.warning("[campaign] quick build failed: #{inspect(result)}")

    {:noreply,
     socket
     |> assign(building: false, build_progress: nil)
     |> put_flash(:error, "Quick build failed: #{inspect(reason(result))}")}
  end

  # Progress from the running Quick Build (sent by its :progress callback).
  def handle_info({:quick_build_progress, %{} = step}, socket) do
    {:noreply,
     if(socket.assigns.building, do: assign(socket, build_progress: step), else: socket)}
  end

  # Open the scene for the ready cast (the arc-review gate has passed).
  defp start_scene(socket, ready, pending) do
    %{entry: entry, payload: payload} = socket.assigns

    scene_id = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
    premise = payload[:premise] || ""
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

    {:noreply, socket |> maybe_flash_pending(pending) |> redirect(to: ~p"/play/#{scene_id}")}
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
        %{"name" => char_name(c), "premise" => Map.get(s, :premise)}
      end

    [world: world, cast: cast]
  end

  defp world_display(wb) do
    %{
      "name" => Map.get(wb, :name) || "",
      "setting" => Map.get(wb, :setting) || "",
      "tone" => Map.get(wb, :tone) || "",
      "rules" => Enum.join(Map.get(wb, :rules) || [], "\n"),
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

  # The bar fills as each phase *completes*: `done` is the count finished, so the bar
  # shows the fraction done while the label names the phase now in flight.
  defp qb_pct(%{done: done, total: total}) when is_integer(total) and total > 0,
    do: round(done / total * 100)

  defp qb_pct(_), do: 0

  # Surface any per-character generation failures on top of the success flash, naming
  # the seeds and the reason so the author can retry just those.
  defp flash_failures(socket, []), do: socket

  defp flash_failures(socket, failed) do
    listed = Enum.map_join(failed, "; ", fn {seed, reason} -> "#{seed} (#{inspect(reason)})" end)

    put_flash(
      socket,
      :error,
      "#{length(failed)} character(s) couldn't be generated — add them by hand or retry: #{listed}"
    )
  end

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

  def render(assigns) do
    ~H"""
    <Kit.frame class="flex flex-col min-h-[100dvh]">
      <Kit.header title={campaign_title(@payload)} subtitle={campaign_meta(assigns)}>
        <:actions>
          <Kit.pill><%= String.capitalize(to_string(@entry.visibility)) %></Kit.pill>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <Kit.tabs>
        <:tab
          :for={{slug, label} <- tabs()}
          patch={~p"/campaigns/#{@entry.id}?#{[tab: slug]}"}
          on={@tab == slug}
          todo={unbuilt?(assigns, slug)}
        >
          <%= label %>
        </:tab>
      </Kit.tabs>

      <div class="flex-1 min-h-0 overflow-y-auto">
        <.settings_tab :if={@tab == "settings"} {assigns} />
        <.world_tab :if={@tab == "world"} {assigns} />
        <.cast_tab :if={@tab == "cast"} {assigns} />
        <.premise_tab :if={@tab == "premise"} {assigns} />
        <.scenes_tab :if={@tab == "scenes"} {assigns} />
      </div>
    </Kit.frame>
    """
  end

  # ── Settings ──────────────────────────────────────────────────────────────────

  defp settings_tab(assigns) do
    ~H"""
    <div class="px-4 py-4 space-y-4">
      <%!-- First run only. The design's own argument for Quick Build being a card and
            not a tab: it's a one-shot, and a tab for it would be dead weight from the
            second day of a campaign's life. --%>
      <div
        :if={first_run?(assigns)}
        class="rounded-xl p-4"
        style="background:color-mix(in srgb,var(--lamp) 10%,transparent);border:1px solid var(--lamp)"
      >
        <div class="ttl text-[16px] mb-1 font-semibold">Build the whole thing at once</div>
        <p class="text-[13px] leading-relaxed dim mb-3">
          Say as much or as little as you like about the story and get a world, a cast who
          already know each other, and a pitch. You can change any of it after.
        </p>
        <Kit.btn kind={:primary} type="button" phx-click="toggle_quick_build">
          <%= if @quick_build_open, do: "Not now", else: "Try Quick Build" %>
        </Kit.btn>
      </div>

      <.quick_build :if={quick_build_open?(assigns)} {assigns} />

      <form id="campaign-details" phx-change="update_details">
        <label for="campaign-name" class="lbl dim">Campaign name</label>
        <input
          id="campaign-name"
          type="text"
          name="name"
          value={@payload[:name]}
          placeholder="Name this campaign…"
          phx-debounce="blur"
          class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
        />
      </form>

      <form id="campaign-content" phx-change="update_content">
        <div class="lbl dim mb-2">What this campaign can contain</div>
        <Kit.sheet class="px-3.5 py-3">
          <label class="flex items-center justify-between gap-3 cursor-pointer">
            <span>
              <span class="text-[14px] font-semibold block">Adult content</span>
              <span class="text-[11px] dim">Off by default, even though you can turn it on</span>
            </span>
            <input type="checkbox" name="adult_content" value="true" checked={@content.adult_content} class="sr-only peer" />
            <Kit.sw on={@content.adult_content} />
          </label>

          <div :if={@content.adult_content} class="space-y-2.5 pt-3 mt-3" style="border-top:1px solid var(--rule)">
            <label :for={{field, label} <- content_categories()} class="flex items-center justify-between cursor-pointer">
              <span class="text-[13px]"><%= label %></span>
              <input type="checkbox" name={field} value="true" checked={Map.get(@content, String.to_existing_atom(field))} class="sr-only" />
              <Kit.sw on={Map.get(@content, String.to_existing_atom(field))} />
            </label>
          </div>

          <%!-- The ceiling stated in the author's vocabulary, not the config's — the
                copy rule that the model's words aren't the author's. --%>
          <div class="rounded-lg px-3 py-2 mt-3" style="background:var(--b3)">
            <div class="lbl dim mb-0.5">This campaign plays as</div>
            <div class="text-[13.5px] font-semibold leading-snug"><%= CampaignConfig.label(@content) %></div>
          </div>
          <p class="text-[11px] leading-relaxed dim mt-2">
            A ceiling, not a target. A character's own limits still hold underneath it, and a
            boundary in a disabled category is forced closed in play (§A5).
          </p>
        </Kit.sheet>
      </form>

      <details>
        <summary class="lbl dim cursor-pointer">Model tuning</summary>
        <form id="campaign-tuning" phx-change="update_details" class="mt-2">
          <Kit.sheet class="px-3.5 py-3 space-y-3">
            <label class="flex items-center justify-between gap-3 cursor-pointer">
              <span class="text-[13px]">Director reasoning (“thinking”)</span>
              <input type="checkbox" name="director_thinking" value="true" checked={@llm.director_thinking} class="sr-only" />
              <Kit.sw on={@llm.director_thinking} />
            </label>
            <div class="flex flex-wrap gap-3">
              <label class="flex-1 min-w-[8rem]">
                <span class="lbl dim">Director max tokens</span>
                <input type="number" name="director_max_tokens" value={@llm.director_max_tokens} min="256" step="128" phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
              </label>
              <label class="flex-1 min-w-[8rem]">
                <span class="lbl dim">Character max tokens</span>
                <input type="number" name="character_max_tokens" value={@llm.character_max_tokens} min="256" step="128" phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
              </label>
            </div>
            <label class="block">
              <span class="lbl dim">Model</span>
              <input type="text" name="model" value={@llm.model} placeholder={@global_models.workhorse || "DEEPINFRA_MODEL"} phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
            </label>
            <label class="block">
              <span class="lbl dim">Heavy fallback model</span>
              <input type="text" name="heavy_model" value={@llm.heavy_model} placeholder={@global_models.heavy || "DEEPINFRA_MODEL_HEAVY"} phx-debounce="blur" class="field px-3 py-2 text-[13px] w-full mt-1" />
            </label>
            <label class="block">
              <span class="lbl dim">Service tier</span>
              <select name="service_tier" class="field px-3 py-2 text-[13px] w-full mt-1">
                <option value="" selected={@llm.service_tier in [nil, ""]}>Standard</option>
                <option value="priority" selected={@llm.service_tier == "priority"}>Priority — jump the queue</option>
                <option value="flex" selected={@llm.service_tier == "flex"}>Flex — cheaper, slower</option>
              </select>
            </label>
            <p class="text-[11px] leading-relaxed dim">
              Point a campaign at a better-provisioned model, or set Priority, when the default
              is overloaded. Takes effect on the next beat.
            </p>
          </Kit.sheet>
        </form>
      </details>
    </div>
    """
  end

  defp quick_build(assigns) do
    ~H"""
    <Kit.sheet class="px-3.5 py-3">
      <form id="quick-build" phx-submit="quick_build" phx-change="sync_quick_build">
        <label for="qb-world" class="lbl dim">World seed</label>
        <textarea
          id="qb-world"
          name="world_seed"
          rows="2"
          phx-debounce="blur"
          class="field px-3 py-2.5 text-[13px] w-full mt-1.5"
          placeholder="A rain-drowned harbour city where debts are paid in memories."
        ><%= @qb_world %></textarea>

        <div class="lbl dim mt-3 mb-1.5">Characters — one concept each</div>
        <div :for={{seed, i} <- Enum.with_index(@qb_seeds)} class="flex gap-1.5 mb-1.5">
          <input
            type="text"
            name="char_seed[]"
            value={seed}
            phx-debounce="blur"
            placeholder="a disgraced harbour-master who sold her own past"
            class="field px-3 py-2 text-[13px] flex-1"
          />
          <Kit.btn kind={:pen} type="button" phx-click="remove_seed" phx-value-index={i} disabled={length(@qb_seeds) <= 1}>
            ✕
          </Kit.btn>
        </div>
        <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="add_seed">+ character</Kit.btn>

        <label class="flex items-center justify-between gap-3 mt-3 cursor-pointer">
          <span class="text-[13px]">
            Also suggest off-screen relationships
            <span class="text-[11px] dim block">Stubs mentors, rivals and family for each character</span>
          </span>
          <input type="checkbox" name="suggest_offscreen" value="true" checked={@qb_suggest} class="sr-only" />
          <Kit.sw on={@qb_suggest} />
        </label>

        <div class="mt-3">
          <Kit.btn kind={:primary} type="submit" disabled={@building}>
            <%= if @building, do: "✦ Building…", else: "✦ Quick build" %>
          </Kit.btn>
        </div>

        <div :if={@building and @build_progress} class="mt-3">
          <Kit.bar fraction={qb_pct(@build_progress) / 100} />
          <div class="text-[11px] dim mt-1.5">
            <%= @build_progress.label %>…
            <span class="mono">(<%= min(@build_progress.done + 1, @build_progress.total) %>/<%= @build_progress.total %>)</span>
          </div>
        </div>
      </form>
    </Kit.sheet>
    """
  end

  # ── World ─────────────────────────────────────────────────────────────────────

  defp world_tab(assigns) do
    ~H"""
    <div>
      <%!-- `ux/polyphony-campaign.html` §04 "Attached", which had never been ported:
            the tab showed the picker and nothing whatever about the world it had
            picked. A quick-built campaign therefore read as a name in a dropdown and
            no setting at all — the world had been written, it just wasn't on screen. --%>
      <.attached_world :if={@world} {assigns} />

      <Kit.row
        :if={is_nil(@world)}
        class="px-4 py-2.5 flex items-center justify-between gap-2"
        style="background:var(--b2)"
      >
        <span class="lbl dim">The world</span>
      </Kit.row>

      <div class="px-4 py-3.5">
        <p class="text-[13px] leading-relaxed dim mb-3">
          The world bible grounds the setting for this campaign's scenes and its published
          snapshot. Attaching one copies it — a campaign accumulates its own world arc, so two
          campaigns can't share a bible.
        </p>
        <form id="campaign-world" phx-change="select_world">
          <label for="bible-select" class="sr-only">World</label>
          <select id="bible-select" name="bible_id" class="field px-3 py-2.5 text-[14px] w-full">
            <option value="">— none —</option>
            <option :for={b <- @bibles} value={b.id} selected={@bible_id == b.id}>
              <%= bible_label_of(b) %>
            </option>
          </select>
        </form>
      </div>

      <Kit.empty :if={@bibles == []} headline="No worlds written yet.">
        A campaign can play without one, but the Director has less to go on.
        <:action>
          <.link navigate={~p"/library"} class="btn btn-pri btn-sm">Go to your stuff</.link>
        </:action>
      </Kit.empty>
    </div>
    """
  end

  # The attached world, read rather than edited — enough to know what the Director is
  # working from without leaving the campaign. Every section is guarded, because a world
  # attached by hand can be a name and nothing else, and a heading over an empty space
  # reads as a bug rather than as an absence.
  defp attached_world(assigns) do
    ~H"""
    <div>
      <Kit.row
        class="px-4 py-3 flex items-center justify-between gap-2"
        style="background:var(--b2)"
      >
        <div class="min-w-0">
          <div class="ttl text-[15px] font-semibold truncate"><%= @bible_name %></div>
          <%!-- Attaching **copies** (§2.5b), so this is no longer the library's world:
                editing here can't reach back and change the template, and the label is
                the only place that's visible. --%>
          <div class="lbl dim mt-0.5">This campaign's copy</div>
        </div>
        <.link navigate={~p"/authoring/bible/#{@bible_id}"} class="btn btn-gh btn-sm shrink-0">
          Edit
        </.link>
      </Kit.row>

      <Kit.row :if={filled(@world.setting)} class="px-4 py-3">
        <div class="lbl dim mb-1">Setting</div>
        <p class="text-[13px] leading-relaxed"><%= @world.setting %></p>
      </Kit.row>

      <Kit.row :if={filled(@world.tone)} class="px-4 py-3">
        <div class="lbl dim mb-1">Tone</div>
        <p class="text-[13px] leading-relaxed"><%= @world.tone %></p>
      </Kit.row>

      <Kit.row :if={world_rules(@world) != []} class="px-4 py-3">
        <div class="lbl dim mb-1.5">Rules</div>
        <div class="space-y-1 text-[13px] leading-relaxed">
          <%!-- Concealed rules are shown: the author is omniscient over their own
                world, and `:secret` is the same mark the bible editor gives them, so
                the two screens don't describe the same entry differently. What a
                *character* may know is `Polyphony.Visibility`'s business and is not
                this screen. --%>
          <Kit.marked
            :for={{entry, i} <- Enum.with_index(world_rules(@world), 1)}
            mark={if(entry.concealed, do: :secret, else: :plain)}
            class="flex gap-2"
          >
            <span class="dim mono text-[11px] pt-0.5"><%= i %></span>
            <span><%= entry.statement %></span>
          </Kit.marked>
        </div>
      </Kit.row>
    </div>
    """
  end

  defp world_rules(%WorldBible{rules: rules}), do: WorldBible.entries(rules)
  defp world_rules(_), do: []

  defp filled(value), do: is_binary(value) and String.trim(value) != ""

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

  defp group_name(_entry, %{name: n}) when is_binary(n) and n != "", do: n
  defp group_name(entry, _group), do: "Unnamed group (##{entry.id})"

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
  defp publish_panel(assigns) do
    ~H"""
    <Kit.row class="px-4 py-3" style="background:var(--b2)">
      <div class="flex items-center gap-1.5 mb-2">
        <span class="lbl dim">How it's meant to be read</span>
        <Kit.info label="publishing" phx-click="publish_help" />
      </div>

      <div class="flex flex-col gap-1.5 mb-3">
        <label class="flex items-center gap-2.5 text-[13px]">
          <Kit.chk state={if @pub_spectator, do: :on, else: :off} phx-click="toggle_spectator" />
          <span class="flex-1">
            As a spectator
            <span class="dim">— everything said and done, nobody's thoughts</span>
          </span>
        </label>

        <%!-- The spoiler control, not a reading preference: publishing a head hands
              away everything in it, and only the author knows which are meant to be
              read. So nothing here is ticked by default. --%>
        <label :for={c <- @cast} class="flex items-center gap-2.5 text-[13px]">
          <Kit.chk
            state={if to_string(c.id) in @pub_perspectives, do: :on, else: :off}
            phx-click="toggle_perspective"
            phx-value-id={c.id}
          />
          <span class="av shrink-0" style={"background:#{Voice.of_sheet(Library.payload(c))}"}></span>
          <span class="flex-1">As <%= char_name(c) %></span>
        </label>
      </div>

      <div class="lbl dim mb-1.5">And whether it can be carried on</div>
      <label class="flex items-center gap-2.5 text-[13px] mb-3">
        <Kit.chk state={if @pub_forkable, do: :on, else: :off} phx-click="toggle_forkable" />
        <span class="flex-1">
          Forkable
          <span class="dim">— world, cast, sheets and arc, so someone can continue it</span>
        </span>
      </label>

      <%!-- The gap can be the point; it just must not happen by accident (§3.1c-ii). --%>
      <div
        :if={@publish_warning}
        class="rounded-lg p-2.5 mb-3"
        style="background:color-mix(in srgb,var(--lamp) 10%,transparent);border-left:2px solid var(--lamp)"
      >
        <div class="text-[12.5px] font-semibold mb-0.5"><%= unreadable_line(@publish_warning) %></div>
        <p class="text-[12px] leading-relaxed dim">
          <span class="ttl"><%= warned_titles(@publish_warning) %></span>
          — nobody you've shared was in
          <%= if length(@publish_warning.scenes) == 1, do: "it", else: "them" %>. Readers will see
          that it happened and no more.
        </p>
        <p class="text-[11px] leading-relaxed dim mt-1.5">
          Sometimes a gap is the point. Worth knowing you've made one.
        </p>
      </div>

      <div class="flex flex-wrap items-center gap-1.5">
        <Kit.btn
          kind={:primary}
          size={:sm}
          phx-click="publish"
          data-confirm={publish_confirm(assigns)}
          disabled={@pub_perspectives == [] and not @pub_spectator}
        >
          <%= if @published?, do: "Update what's published", else: "Publish" %>
        </Kit.btn>
        <span :if={@pub_perspectives == [] and not @pub_spectator} class="text-[11px] dim">
          Pick at least one way to read it.
        </span>
      </div>
    </Kit.row>
    """
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

  defp publication(socket) do
    %Publication{
      perspectives: socket.assigns.pub_perspectives,
      spectator: socket.assigns.pub_spectator,
      forkable: socket.assigns.pub_forkable
    }
  end

  # Recomputed whenever the grant changes, so the warning tracks what's actually ticked
  # rather than appearing once at the end. Only the reading half matters — forkable
  # can't make a scene unreachable.
  defp preflight(socket) do
    scenes = Preflight.scenes(socket.assigns.scenes)
    assign(socket, publish_warning: Preflight.warning(publication(socket), scenes))
  end

  defp unreadable_line(%{scenes: [_]}), do: "One scene nobody will be able to read"
  defp unreadable_line(%{scenes: s}), do: "#{length(s)} scenes nobody will be able to read"

  defp warned_titles(%{scenes: scenes}),
    do: scenes |> Enum.map(&Map.get(&1, :title)) |> Enum.join(", ")

  defp publish_confirm(assigns) do
    heads = length(assigns.pub_perspectives)

    read =
      cond do
        heads > 1 -> "#{heads} people's heads"
        heads == 1 -> "one person's head"
        true -> "no interiority"
      end

    fork = if assigns.pub_forkable, do: " They can also take a copy and carry it on.", else: ""

    if assigns.published? do
      "Replace what's published? Readers get #{read}, including anyone partway through — " <>
        "there's one published copy and this becomes it." <> fork
    else
      "Publish a public copy? Readers get #{read}." <> fork
    end
  end

  # ── Cast ──────────────────────────────────────────────────────────────────────

  defp cast_tab(assigns) do
    ~H"""
    <div>
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim">Cast · <%= length(@cast) %></span>
        <div class="flex gap-1.5">
          <Kit.btn size={:sm} type="button" phx-click="new_character">✦ Write one</Kit.btn>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="start_scene" disabled={@cast == []}>
            Set a scene
          </Kit.btn>
        </div>
      </Kit.row>

      <%!-- Stubs come from other people's relationships, so they arrive in batches.
            One button fills them all rather than twenty trips through the editor. --%>
      <Kit.row
        :if={pending_count(@cast) > 0}
        class="px-4 py-2.5 flex items-center justify-between gap-2"
      >
        <span class="text-[12px] dim">
          <%= pending_line(pending_count(@cast)) %> — stubs from relationships, not written yet.
        </span>
        <Kit.btn size={:sm} type="button" phx-click="generate_pending" disabled={@generating}>
          <%= if @generating, do: "Filling them in…", else: "Fill them in" %>
        </Kit.btn>
      </Kit.row>

      <Kit.row :for={c <- @cast} class="px-4 py-2.5 flex items-center gap-2.5">
        <span class="av shrink-0" style={"background:#{Voice.of_sheet(Library.payload(c))}"}></span>
        <div class="min-w-0 flex-1">
          <div class="text-[13.5px] font-semibold"><%= char_name(c) %></div>
          <div class="text-[11px] dim truncate"><%= char_blurb(c) %></div>
        </div>
        <Kit.pill :if={pending?(c)} colour="var(--lamp)">Pending</Kit.pill>
        <.link navigate={~p"/authoring/character/#{c.id}"} class="btn btn-gh btn-sm shrink-0">Edit</.link>
        <Kit.btn kind={:pen} size={:sm} phx-click="remove_character" phx-value-id={c.id}>Remove</Kit.btn>
      </Kit.row>

      <Kit.empty :if={@cast == []} headline="Nobody is in this story yet.">
        A campaign needs at least one character before a scene can open.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="new_character">
            ✦ Write a character
          </Kit.btn>
        </:action>
      </Kit.empty>

      <div :if={@addable != []} class="px-4 py-3" style="background:var(--b2)">
        <form id="add-character" phx-submit="add_character" class="flex gap-1.5">
          <label for="add-character-select" class="sr-only">Add a character</label>
          <select id="add-character-select" name="id" class="field px-3 py-2 text-[13px] flex-1">
            <option :for={c <- @addable} value={c.id}>
              <%= char_name(c) %><%= if pending?(c), do: " (pending)", else: "" %>
            </option>
          </select>
          <Kit.btn kind={:ghost} type="submit">Add</Kit.btn>
        </form>
      </div>

      <p :if={@addable == [] and @cast != []} class="px-4 py-3 text-[11px] leading-relaxed dim">
        Everyone you've written<span :if={@bible_name}> in <%= @bible_name %></span> is already
        in the cast.
      </p>

      <%!-- Beside Cast, per §06b: groups are written with the character editor and
            seed the people they produce, so this is where they belong rather than in
            a corner of their own. --%>
      <.groups_card {assigns} />

      <.publish_panel {assigns} />
    </div>
    """
  end

  # ── Premise ───────────────────────────────────────────────────────────────────

  defp premise_tab(assigns) do
    ~H"""
    <div class="px-4 py-4">
      <%!-- Premise comes after Cast in the tab order because the pitch is written
            *from* the cast — which is also what Expand reads. --%>
      <div class="flex items-center justify-between gap-2 mb-2">
        <span class="lbl dim">What this story is about</span>
        <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="expand_premise" disabled={@expanding_premise}>
          <%= if @expanding_premise, do: "✦ …", else: "✦ Expand" %>
        </Kit.btn>
      </div>

      <form id="campaign-premise" phx-change="update_details">
        <label for="premise-input" class="sr-only">Premise</label>
        <textarea
          id="premise-input"
          name="premise"
          rows="8"
          phx-debounce="blur"
          class="field px-3.5 py-3 text-[14px] leading-relaxed w-full"
          placeholder="A shipment came in that isn't on any manifest…"
        ><%= @payload[:premise] %></textarea>
      </form>

      <p class="text-[11px] leading-relaxed dim mt-2">
        Expand deepens whatever's saved, grounded in the world and the cast — so it reads best
        once both exist.
      </p>
    </div>
    """
  end

  # `ux/polyphony-campaign.html` §06b, which had no implementation at all — the domain
  # could seed from a group, resolve an audience through one, and fan its arc out to
  # every member, and there was no way to make one.
  defp groups_card(assigns) do
    ~H"""
    <Kit.sheet class="m-4">
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim">Groups · <%= length(@groups) %></span>
        <Kit.btn size={:sm} type="button" phx-click="new_group">✦ Write one</Kit.btn>
      </Kit.row>

      <Kit.row :for={g <- @groups} class="px-4 py-2.5 flex items-center gap-2.5">
        <span class="av shrink-0" style={"background:#{g.colour}"}></span>
        <.link navigate={~p"/authoring/group/#{g.id}"} class="min-w-0 flex-1">
          <div class="text-[13.5px] font-semibold truncate"><%= g.name %></div>
          <div class="text-[11px] dim"><%= group_line(g) %></div>
        </.link>
        <span class="dim text-[14px] shrink-0">›</span>
      </Kit.row>

      <div :if={@groups != []} class="px-4 py-2.5">
        <p class="text-[11px] leading-relaxed dim">
          Anyone written from a group starts with its fields and knows whatever it knows.
        </p>
      </div>

      <Kit.empty :if={@groups == []} headline="No groups yet." class="py-6">
        A group is written like a character and used as a starting point for others — a
        crew, a household, an order. It saves writing the same person five times, and
        gives secrets somewhere to point.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="new_group">
            ✦ Write a group
          </Kit.btn>
        </:action>
      </Kit.empty>
    </Kit.sheet>
    """
  end

  # The design's own line: "6 members · seeds new people · 2 secrets".
  defp group_line(g) do
    [
      "#{g.members} member#{if g.members == 1, do: "", else: "s"}",
      "seeds new people",
      g.secrets > 0 && "#{g.secrets} secret#{if g.secrets == 1, do: "", else: "s"}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # ── Scenes ────────────────────────────────────────────────────────────────────

  defp scenes_tab(assigns) do
    ~H"""
    <div>
      <Kit.row class="px-4 py-2.5 flex items-center justify-between gap-2" style="background:var(--b2)">
        <span class="lbl dim"><%= length(@scenes) %> <%= if length(@scenes) == 1, do: "scene", else: "scenes" %></span>
        <Kit.btn kind={:primary} size={:sm} type="button" phx-click="start_scene" disabled={@cast == []}>
          Set a scene
        </Kit.btn>
      </Kit.row>

      <%!-- `OpenScene` has carried `location_id` since §2.3 and nothing ever passed
            one, so every scene opened nowhere. It is a reference field on purpose — a
            string today, a location entity later without changing the event — which is
            why this is a line of text rather than a picker. --%>
      <Kit.row class="px-4 py-3">
        <form id="scene-where" phx-change="set_scene_location">
          <label for="scene-location" class="lbl dim">Where the next scene happens</label>
          <input
            id="scene-location"
            type="text"
            name="location"
            value={@scene_location}
            phx-debounce="blur"
            placeholder="The quay, after the second bell"
            class="field px-3 py-2.5 text-[14px] w-full mt-1.5"
          />
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            The Director opens there, and it grounds what everyone can see.
          </p>
        </form>
      </Kit.row>

      <Kit.row :for={s <- @scenes} class="px-4 py-3">
        <.link navigate={~p"/play/#{s}"} class="flex items-center justify-between gap-2">
          <span class="ttl text-[14.5px] font-semibold min-w-0 truncate"><%= scene_label(s) %></span>
          <span class="dim text-[14px] shrink-0">›</span>
        </.link>
      </Kit.row>

      <Kit.empty :if={@scenes == []} headline="Nothing has happened yet.">
        Set a scene and the Director will open it.
        <:action>
          <Kit.btn kind={:primary} size={:sm} type="button" phx-click="start_scene" disabled={@cast == []}>
            Set a scene
          </Kit.btn>
        </:action>
      </Kit.empty>

      <Kit.row class="px-4 py-3 flex items-center justify-between gap-2">
        <div class="min-w-0">
          <div class="text-[13px] font-semibold">What play has changed</div>
          <div class="text-[11px] dim">Arc the scenes proposed, waiting on you</div>
        </div>
        <.link navigate={~p"/arc/#{@entry.id}"} class="btn btn-gh btn-sm shrink-0">Review</.link>
      </Kit.row>
    </div>
    """
  end

  # ── Render helpers ────────────────────────────────────────────────────────────

  defp campaign_title(payload) do
    case payload[:name] do
      n when is_binary(n) and n != "" -> n
      _ -> "Untitled campaign"
    end
  end

  # The meta line the mock puts under the title: world, cast size, scene count. Says
  # "Nothing built yet" on a campaign that has none of them rather than "0 · 0".
  defp campaign_meta(assigns) do
    parts =
      [
        assigns.bible_name,
        count_label(length(assigns.cast), "cast", "cast"),
        count_label(length(assigns.scenes), "scene", "scenes")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "Nothing built yet", else: Enum.join(parts, " · ")
  end

  defp count_label(0, _one, _many), do: nil
  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(n, _one, many), do: "#{n} #{many}"

  # The kit's amber dot on a tab means *unbuilt*, and the mock uses it only on a
  # campaign's first run — an invitation, not an error. So it goes once something
  # exists anywhere.
  defp unbuilt?(assigns, slug) do
    first_run?(assigns) and
      case slug do
        "world" -> is_nil(assigns.bible_id)
        "cast" -> assigns.cast == []
        "premise" -> assigns.payload[:premise] in [nil, ""]
        _ -> false
      end
  end

  defp first_run?(assigns),
    do: assigns.cast == [] and is_nil(assigns.bible_id) and assigns.scenes == []

  # The card and the form it opens are one thing, so they ask one question. They drifted
  # apart: the card is first-run only, but the form was shown on the open flag alone —
  # and a successful build never cleared it. So the card vanished the moment the
  # campaign stopped being first-run, and the form it had opened stayed on screen,
  # offering to build a world and cast that now existed, underneath the settings for
  # them.
  defp quick_build_open?(assigns), do: assigns.quick_build_open and first_run?(assigns)

  defp content_categories,
    do: [
      {"sexual", "Sex"},
      {"graphic_violence", "Graphic violence"},
      {"other", "Other mature themes"}
    ]

  defp char_blurb(entry) do
    case Library.payload(entry) do
      %CharacterSheet{premise: p} when is_binary(p) and p != "" -> p
      _ -> "No sheet written yet"
    end
  end

  defp scene_label(scene_id), do: "Scene " <> String.slice(to_string(scene_id), 0, 12)

  defp char_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "char-#{entry.id}"
    end
  end

  defp update_cast(socket, ids, flash) do
    payload = Map.put(socket.assigns.payload, :character_ids, ids)
    {:ok, entry} = Library.update_payload(socket.assigns.entry.id, payload)
    socket |> assign(entry: entry) |> load() |> put_flash(:info, flash)
  end

  # The cast as a list of integer library ids (tolerating any legacy name entries,
  # which simply won't resolve to a character and drop out).
  defp cast_ids(payload) do
    (payload[:character_ids] || []) |> Enum.map(&normalize_id/1) |> Enum.reject(&is_nil/1)
  end

  defp display_name(nil), do: "character"

  defp display_name(id) do
    case Library.get(id) do
      nil -> "character"
      entry -> char_name(entry)
    end
  end

  defp full?(entry), do: match?(%CharacterSheet{status: :full}, Library.payload(entry))

  defp maybe_flash_pending(socket, []), do: socket

  defp maybe_flash_pending(socket, pending),
    do:
      put_flash(
        socket,
        :info,
        "Skipped #{length(pending)} pending character(s) — generate them, then re-add to a scene."
      )

  defp attach_world(_socket, ""), do: {nil, "World removed."}

  defp attach_world(socket, id) do
    source = Library.get(String.to_integer(id))

    cond do
      is_nil(source) ->
        {nil, "That world is gone."}

      # Already this campaign's own copy — re-selecting it must not copy the copy.
      source.id == socket.assigns.payload[:bible_id] ->
        {source.id, "World updated."}

      true ->
        copy = Library.copy(source, socket.assigns.current_user)
        {copy.id, "This campaign has its own copy of #{world_name(source)} now."}
    end
  end

  defp world_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "that world"
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  # With no world attached, every owned character is addable; with one attached, the
  # roster is scoped to that world's characters plus any not yet assigned to a world.
  defp addable_in_world?(_char, nil), do: true

  defp addable_in_world?(char, world_id) do
    wid = char |> Library.payload() |> Map.get(:world_bible_id)
    wid in [nil, world_id]
  end

  defp pending?(char) do
    match?(%CharacterSheet{status: s} when s != :full, Library.payload(char))
  end

  # Best-effort per stub: one that can't be filled leaves the rest alone and says so.
  defp generate_stubs(stubs, user) do
    uid = user && user.id

    Enum.reduce(stubs, {0, 0}, fn entry, {ok, bad} ->
      case StubGen.finalize(entry, uid) do
        :ok -> {ok + 1, bad}
        :error -> {ok, bad + 1}
      end
    end)
  end

  defp pending_count(cast), do: Enum.count(cast, &pending?/1)

  defp pending_line(1), do: "1 pending character"
  defp pending_line(n), do: "#{n} pending characters"

  defp bible_label(_bibles, nil), do: nil

  defp bible_label(bibles, id) do
    case Enum.find(bibles, &(&1.id == id)) do
      nil -> nil
      entry -> bible_label_of(entry)
    end
  end

  defp bible_label_of(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> "Untitled world (##{entry.id})"
    end
  end
end
