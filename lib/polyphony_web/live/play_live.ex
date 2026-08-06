defmodule PolyphonyWeb.PlayLive do
  @moduledoc """
  V1 (Play) — the core. Renders a scene as a **viewer-parameterized** projection:
  switch between the omniscient author view and any character's filtered view, and a
  whisper the character wasn't part of is silently absent (occlusion is silent, §8).

  The transcript streams live off the §13 per-viewer broadcaster: the LiveView
  subscribes to `Broadcast.topic(scene, viewer)` and renders committed packets (never
  tokens). The composer commits a user turn directly; **Continue** advances the beat
  and lets the autonomous cast respond through the Oban Director loop. Three distinct
  waiting states, per the FS principle.

  ## Identity: ids in, names out (§5.2)

  This view is **id-native**. Everything that routes — the viewer, the roster, the
  speaker, control modes, packet ids, whisper addressees — is a stable character id
  (the library entry's id, minted at `EnterCharacter`). Everything a person reads or
  types is a display name, resolved through `Polyphony.Scene.Cast` at the edge:
  `render_name/2` on the way out, `resolve_addressees/2` on the way in, immediately
  before `CommitPacket`.

  The point is that renaming a character can't corrupt a scene. A whisper addressed
  to an id keeps reaching the same person after a rename; a whisper addressed to a
  name would silently stop — fail-*safe* under default-deny (nobody sees it who
  shouldn't), but a real bug. Nothing here may put a name where a routing key
  belongs.
  """
  use PolyphonyWeb, :live_view

  require Logger

  alias Polyphony.{
    App,
    Broadcast,
    Context,
    DebugFlags,
    Drafts,
    Failures,
    Library,
    MembershipSet,
    Owner,
    SceneControl,
    TurnOrder
  }

  alias Polyphony.Context.{Store, PgvectorRetriever, Rebuild}
  alias Polyphony.Director.BeatDriver
  alias Polyphony.Campaigns
  alias Polyphony.Edit
  alias Polyphony.Generations
  alias Polyphony.Permissions
  alias Polyphony.Scene.Cast
  alias PolyphonyWeb.Kit
  alias PolyphonyWeb.Transcript
  alias PolyphonyWeb.Layouts
  alias PolyphonyWeb.Play.Strip
  alias PolyphonyWeb.Voice
  alias Polyphony.Authoring.Effective
  alias Polyphony.DebugTap
  alias Polyphony.Director.{BeatOps, SceneBrief}

  alias Polyphony.Commands.{
    CommitPacket,
    DeclareTurnOrder,
    EnterCharacter,
    DismissIntroduction,
    RecordWorldEvent,
    SetControlMode,
    SupersedePacket
  }

  alias Polyphony.Authoring.{CharacterSheet, Stub, WorldBible}

  alias Polyphony.Events.{
    IntroductionProposed,
    IntroductionDismissed,
    CharacterEntered,
    SceneOpened,
    SpeechUttered,
    ActionTaken,
    WorldEventOccurred
  }

  alias Polyphony.TurnPacket
  alias PolyphonyWeb.TurnEdit

  def mount(%{"scene_id" => scene_id}, _session, socket) do
    # A scene is an event stream rather than a library entry, so its access is its
    # **campaign's** — playing writes fiction into somebody's story, which is editing it
    # under another name. Scene ids are `sc-<counter>`, so without this any signed-in
    # account could walk into a stranger's scene and take a turn in it.
    if Permissions.can_play?(campaign_of(scene_id), socket.assigns.current_user) do
      mount_scene(scene_id, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "Scene not found.")
       |> redirect(to: ~p"/library")}
    end
  end

  defp mount_scene(scene_id, socket) do
    if connected?(socket) do
      DebugFlags.subscribe()
      DebugTap.subscribe(scene_id)
      # Beat-loop activity (Director deciding / who's generating / idle) — every viewer
      # subscribes so the indicator is accurate and input can be blocked while a beat runs.
      Phoenix.PubSub.subscribe(Polyphony.PubSub, Broadcast.progress_topic(scene_id))
      # Drafts have a topic of their own — workflow, never fiction — so this holds
      # through a perspective change without ever subscribing a character's view to
      # the omniscient projection.
      Phoenix.PubSub.subscribe(Polyphony.PubSub, Drafts.topic(scene_id))
    end

    socket = assign(socket, scene_id: scene_id)

    {:ok,
     socket
     |> assign(
       scene_id: scene_id,
       page_title: "Play",
       topic: nil,
       joinable: [],
       writable: [],
       writing_in: MapSet.new(),
       cast: %Cast{},
       waiting: :you,
       progress: %{phase: :idle, subject: nil},
       introductions: [],
       control_modes: %{},
       failures: [],
       drafts: [],
       editing_draft: nil,
       editing: nil,
       composing: false,
       debug_events: DebugFlags.get(:events),
       debug_trace: DebugFlags.get(:trace),
       raw_events: [],
       traces: [],
       debug_feed: [],
       debug_feed_text: "",
       premise: "",
       who: nil,
       narrating: false,
       narrating_draft: "",
       drafting_narration: false,
       panel: nil,
       voices: %{},
       campaign_name: "",
       scene_title: "The scene",
       strip: %{slots: [], sentence: nil, tone: nil}
     )
     |> then(&if connected?(&1), do: restore_generations(&1), else: &1)}
  end

  # Viewer is chosen via ?as=<character> (absent → omniscient author view). Runs on
  # first load and on every viewer switch, (re)subscribing to the right topic.
  def handle_params(params, _uri, socket) do
    viewer = parse_viewer(params["as"])
    socket = resubscribe(socket, viewer)

    {:noreply,
     socket
     |> assign(viewer: viewer, speaker: speaker(viewer), register: register_for(viewer))
     |> reload()}
  end

  defp parse_viewer(as) when as in [nil, "", "omniscient"], do: :omniscient
  defp parse_viewer(as), do: {:character, as}

  # The register is the surface's, not the user's (`ux/README.md`): a character in
  # their own head is reading, so `.page`; the omniscient author is working, so
  # `.stage`. Same components either way — different density and warmth.
  defp register_for({:character, _}), do: :page
  defp register_for(_), do: :stage

  # You speak as whoever you're viewing as; omniscient is a read-only vantage.
  defp speaker({:character, c}), do: c
  defp speaker(_), do: nil

  defp resubscribe(socket, viewer) do
    new_topic = Broadcast.topic(socket.assigns.scene_id, viewer)

    if connected?(socket) do
      if socket.assigns.topic,
        do: Phoenix.PubSub.unsubscribe(Polyphony.PubSub, socket.assigns.topic)

      Phoenix.PubSub.subscribe(Polyphony.PubSub, new_topic)
    end

    assign(socket, topic: new_topic)
  end

  defp reload(socket) do
    scene_id = socket.assigns.scene_id
    events = stored_with_seq(scene_id)
    plain = Enum.map(events, &elem(&1, 1))
    member_at? = plain |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    messages = Broadcast.replay(events, socket.assigns.viewer, member_at?, 0)

    next_beat = 1 + Enum.max([0 | Enum.map(plain, &event_beat/1)])
    # The roster is character **ids**; `cast` is how they become readable. Rebuilt on
    # every reload so a rename shows up without a page load.
    roster = BeatOps.members_now(scene_id, max(next_beat - 1, 1))
    cast = Cast.for_scene(scene_id)
    # Voice colours come from the hue stored on each sheet, so they're stable across
    # the transcript, the strip and the perspective control — and stable across a
    # cast change, which is what deriving them from order could never be.
    voices = Map.new(cast.id_to_hue, fn {id, hue} -> {id, Voice.colour(hue)} end)

    traces = if socket.assigns.debug_trace, do: DebugTap.recent(scene_id), else: []
    failures = open_failures(socket)
    feed = debug_feed(socket, traces, failures)

    assign(socket,
      messages: messages,
      raw_events: events,
      traces: traces,
      roster: roster,
      joinable: joinable(socket, roster),
      writable: writable(socket, roster),
      cast: cast,
      voices: voices,
      strip:
        Strip.build(
          beat_events: BeatOps.beat_events(scene_id, max(next_beat - 1, 1)),
          order: TurnOrder.for_beat(plain, max(next_beat - 1, 1)),
          members: roster,
          viewer: socket.assigns.viewer,
          generating: generating_now(socket.assigns.progress),
          names: cast.id_to_name,
          voices: voices
        ),
      next_beat: next_beat,
      premise: scene_premise(plain),
      campaign_name: campaign_name(socket),
      scene_title: scene_title(plain),
      control_modes: Map.new(roster, fn c -> {c, TurnOrder.control_mode(plain, c)} end),
      # The Director's pending introductions — author-facing tooling, so only the
      # omniscient view shows the queue (and each carries how it resolves).
      introductions: intro_queue(socket, plain, cast),
      failures: failures,
      drafts: open_drafts(scene_id),
      debug_feed: feed,
      debug_feed_text: feed_text(feed)
    )
  end

  # Assisted turns awaiting the author (§A2). Not filtered by viewer: a draft is
  # authoring workflow, it has never touched the log, and the person deciding is the
  # author whichever pair of eyes they are currently borrowing. Decoded here so the
  # template renders moves rather than a binary.
  defp open_drafts(scene_id) do
    for row <- Drafts.list_open(scene_id), do: %{row: row, packet: Drafts.packet(row)}
  end

  # Open generation failures for this scene, scoped to the viewer (§1.7): the GM
  # (omniscient) sees all; a character viewer sees only their own turn failures —
  # the ones they can retry. Author-facing failures (summaries, arc) never scope to
  # a character, so a player never sees them.
  defp open_failures(socket) do
    case socket.assigns.viewer do
      :omniscient -> Failures.list_open(socket.assigns.scene_id)
      {:character, id} -> Failures.list_open(socket.assigns.scene_id, subject: id)
    end
  end

  # The header, per the kit's standard header spec: campaign name small, the scene's
  # location as the title. Play and the published reading screen share this markup.
  defp scene_title(plain) do
    Enum.find_value(plain, "The scene", fn
      %SceneOpened{location_id: l} when is_binary(l) and l != "" -> l
      _ -> nil
    end)
  end

  defp campaign_name(socket) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <-
           scene_opened(socket.assigns.scene_id),
         entry when not is_nil(entry) <- Library.get(cid),
         %{name: name} when is_binary(name) <- Library.payload(entry) do
      name
    else
      _ -> ""
    end
  end

  # Who the beat loop is generating right now, if anyone — the strip's live slot.
  defp generating_now(%{phase: :generating, subject: s}) when is_binary(s) and s != "", do: s
  defp generating_now(_), do: nil

  defp scene_premise(plain) do
    Enum.find_value(plain, "", fn
      %SceneOpened{premise: p} -> p || ""
      _ -> nil
    end)
  end

  defp intro_queue(socket, plain, cast) do
    if socket.assigns.viewer == :omniscient do
      by_name = owner_characters(socket.assigns.current_user)

      plain
      |> pending_introductions(cast)
      |> Enum.map(fn intro ->
        entry = Map.get(by_name, String.downcase(intro.name))
        Map.put(intro, :resolution, resolution(entry))
      end)
    else
      []
    end
  end

  # Fold the stream into the still-pending proposals (proposed, minus dismissed, minus
  # those who have since entered).
  defp pending_introductions(plain, cast) do
    plain
    |> Enum.reduce(%{}, fn
      %IntroductionProposed{name: n} = e, acc ->
        Map.put(acc, String.downcase(n), %{name: n, reason: e.reason, beat: e.beat})

      %IntroductionDismissed{name: n}, acc ->
        Map.delete(acc, String.downcase(n))

      # An introduction is proposed by name but entered by id (§5.2), so match the
      # two through the cast — otherwise an admitted character stays in the queue.
      %CharacterEntered{character_id: c}, acc ->
        Map.delete(acc, String.downcase(Cast.render_name(cast, c)))

      _e, acc ->
        acc
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.beat)
  end

  # How a proposed name resolves against the author's library: an existing full
  # character (admit directly), an existing pending stub (generate/edit then admit),
  # or a brand-new name (create + generate, or open a fresh editor).
  defp resolution(nil), do: %{status: :new, entry: nil}

  defp resolution(entry) do
    case Library.payload(entry) do
      %CharacterSheet{status: :full} -> %{status: :ready, entry: entry}
      _ -> %{status: :stub, entry: entry}
    end
  end

  defp owner_characters(user) do
    user
    |> Owner.of()
    |> Library.list_for_owner()
    |> Enum.filter(&(&1.kind == "character"))
    |> Map.new(fn e -> {String.downcase(char_name(e) || ""), e} end)
  end

  # The scene's committed spoken/acted/world prose — the text mention-scanning reads.
  defp scene_prose(scene_id) do
    scene_id
    |> stored_with_seq()
    |> Enum.flat_map(fn {_seq, e} -> prose_of(e) end)
  end

  defp prose_of(%SpeechUttered{content: c}), do: [c]
  defp prose_of(%ActionTaken{content: c}), do: [c]
  defp prose_of(%WorldEventOccurred{content: c}), do: [c]
  defp prose_of(_), do: []

  # Create a pending stub for each mentioned name that isn't already a character or a
  # current scene member. Returns the names actually stubbed.
  defp stub_mentions(socket, names) do
    known = owner_characters(socket.assigns.current_user)
    # The roster is ids; a mention is a name. Compare on names.
    members =
      MapSet.new(
        socket.assigns.roster,
        &String.downcase(Cast.render_name(socket.assigns.cast, &1))
      )

    owner = Owner.of(socket.assigns.current_user)
    world_id = campaign_world_id(socket)
    campaign_id = campaign_of(socket.assigns.scene_id)

    for name <- names,
        key = String.downcase(name),
        not Map.has_key?(known, key),
        not MapSet.member?(members, key) do
      entry =
        Library.put(%{
          owner: owner,
          kind: "character",
          payload: Stub.new(name, "", world_bible_id: world_id)
        })

      # A name the scene mentioned is one of this story's people, whatever else
      # becomes of them.
      Campaigns.cast(campaign_id, entry.id)
      name
    end
  end

  defp char_name(entry) do
    case Library.payload(entry) do
      %{name: n} when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  defp find_owned(socket, name) do
    case Map.get(owner_characters(socket.assigns.current_user), String.downcase(name)) do
      nil ->
        :none

      entry ->
        case Library.payload(entry) do
          %CharacterSheet{status: :full} -> {:full, entry}
          _ -> {:pending, entry}
        end
    end
  end

  # Return the existing library character for `name`, or create a pending stub for it
  # (owned by the author, in the campaign's world) so it can be generated/edited.
  defp ensure_character(socket, name) do
    case Map.get(owner_characters(socket.assigns.current_user), String.downcase(name)) do
      nil ->
        entry =
          Library.put(%{
            owner: Owner.of(socket.assigns.current_user),
            kind: "character",
            payload: Stub.new(name, "", world_bible_id: campaign_world_id(socket))
          })

        # Somebody introduced mid-scene belongs to the story they walked into.
        Campaigns.cast(campaign_of(socket.assigns.scene_id), entry.id)
        entry

      entry ->
        entry
    end
  end

  # Enter a finalized character into the scene at the current beat boundary and seed
  # their frozen context so the Director loop can cast them next. The character enters
  # by **library id** (§5.2) — the same mint as scene open — with the name kept only
  # for what the author reads.
  defp admit(socket, entry, %CharacterSheet{name: name} = sheet) do
    scene_id = socket.assigns.scene_id
    beat = max(socket.assigns.next_beat - 1, 1)
    character_id = to_string(entry.id)

    :ok =
      App.dispatch(%EnterCharacter{scene_id: scene_id, character_id: character_id, beat: beat})

    seed_context(
      scene_id,
      character_id,
      sheet,
      socket.assigns.premise,
      campaign_world_bible(socket)
    )

    # Fold the newcomer into the Director's omniscient brief so the next beat knows them.
    SceneBrief.note_character(scene_id, sheet)
    socket |> reload() |> put_flash(:info, "#{name} joins the scene.")
  end

  defp admit(socket, _entry, _other),
    do: put_flash(socket, :error, "That character has no usable sheet yet.")

  defp seed_context(scene_id, character_id, %CharacterSheet{} = sheet, premise, bible) do
    {campaign_id, location} = scene_campaign_location(scene_id)

    ctx =
      Context.materialize(
        scene_id: scene_id,
        character_id: character_id,
        # Canon character + world arc folded in (§2.8); world facts scoped to this
        # scene's location (global + local-here). Arc keys on the same id the log
        # uses, so accumulated arc survives a rename (§5.2 phase 4).
        sheet: Effective.sheet(sheet, character_id),
        premise: premise,
        world_bible: Effective.world_bible(bible, campaign_id, location),
        # The rest of the cast, so a secret whose audience names this character
        # actually reaches them (§3.3). Live group membership is read here, at scene
        # open, which is what lets a newly-written group member already know.
        cast: Rebuild.cast(scene_id),
        # Retrieve this character's own distant-scene summaries from pgvector
        # (no-ops to [] without egress / when the embed fails).
        retriever: PgvectorRetriever
      )

    Store.put(scene_id, character_id, ctx)
  end

  # The scene's world bible payload (a `%WorldBible{}`), or nil — for framing both
  # the admitted character's context and the Director's omniscient brief.
  defp campaign_world_bible(socket) do
    case campaign_world_id(socket) do
      nil -> nil
      wid -> Library.get(wid) |> maybe_payload()
    end
  end

  # The **public** read of this campaign's world. A narration is written into every
  # member's transcript, so it is character-facing in the strictest sense the app has —
  # more so than a scene premise, which takes the same read for the same reason.
  defp narration_world(socket) do
    case campaign_world_bible(socket) do
      %WorldBible{} = wb ->
        %{
          "name" => wb.name || "",
          "setting" => wb.setting || "",
          "tone" => wb.tone || "",
          "rules" => Enum.join(WorldBible.public(wb.rules), "\n"),
          "starting_canon" => Enum.join(WorldBible.public(wb.starting_canon), "\n")
        }

      _ ->
        nil
    end
  end

  defp narration_meter(socket) do
    uid = socket.assigns.current_user && socket.assigns.current_user.id
    [usage_kind: "authoring"] ++ if(uid, do: [user_id: uid], else: [])
  end

  # What everybody in the scene has already seen: speech that wasn't a whisper, actions,
  # demeanour, and the Director's own moves. Thoughts are structurally invisible to
  # everyone else and a whisper reached two people — feeding either to a drafting aid
  # whose output goes into the shared transcript is how a secret gets narrated out loud.
  @public_kinds ~w(SpeechUttered ActionTaken DemeanorReported WorldEventOccurred)
  @recent_lines 12

  defp public_lines(messages) do
    for m <- messages,
        m[:kind] in @public_kinds,
        p = m[:payload] || %{},
        to_string(p[:audibility]) != "private",
        text = String.trim(to_string(p[:content] || "")),
        text != "" do
      text
    end
    |> Enum.take(-@recent_lines)
  end

  defp maybe_payload(nil), do: nil
  defp maybe_payload(entry), do: Library.payload(entry)

  # The world bible id behind this scene's campaign, for stubbing new introductions
  # into the right setting. Nil if the scene has no campaign or world.
  defp campaign_world_id(socket) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <-
           scene_opened(socket.assigns.scene_id),
         campaign when not is_nil(campaign) <- Library.get(cid),
         %{bible_id: bid} <- Library.payload(campaign) do
      normalize_id(bid)
    else
      _ -> nil
    end
  end

  # Play's generations are keyed on the **scene**, and tracked with the screen's own
  # booleans rather than an editor's key set — so it talks to `Polyphony.Generations`
  # directly. Same durability, same reason: an Expand takes seconds, and the answer must
  # not belong to whichever tab happened to ask for it.
  #
  # The reroll deliberately stays a plain task: it supersedes a packet and enqueues
  # `Jobs.GeneratePacket`, so the generation has always been a job and the replacement
  # arrives on the transcript stream.
  defp request_generation(socket, key, op, request) do
    Generations.request(socket.assigns.scene_id, key, op, request)
    socket
  end

  # Applying a result consumes it, so a live delivery can't be replayed on the next mount.
  defp forget_generation(socket, key) do
    Generations.forget(socket.assigns.scene_id, key)
    socket
  end

  # A reconnect can't see the composer's spinner, and it can't see an answer that
  # arrived while the tab was closed. Both come back from the rows.
  defp restore_generations(socket) do
    scene_id = socket.assigns.scene_id
    Generations.subscribe(scene_id)

    for {key, result} <- Generations.take(scene_id),
        do: send(self(), {:generation, key, result})

    assign(socket, composing: "compose" in Generations.running(scene_id))
  end

  # The campaign's cast who aren't in this scene: castable (`:full` — `SceneControl`
  # refuses anything else) and not already on the roster. Scoped to the campaign rather
  # than the whole library, because §2.7 means a character belongs to one story and the
  # picker for *this* scene should not offer somebody else's people.
  defp joinable(socket, roster) do
    present = MapSet.new(roster, &to_string/1)

    for id <- campaign_character_ids(socket),
        entry = Library.get(id),
        entry != nil,
        not MapSet.member?(present, to_string(entry.id)),
        match?(%CharacterSheet{status: :full}, Library.payload(entry)),
        do: entry
  end

  # The same list, for the people this story invented and never wrote — the walk-ons a
  # character's relationships stubbed. `SceneControl` refuses them, which is why they
  # are a separate list with a separate control rather than more options in the picker:
  # the honest offer is not "bring them in" but "write them, then bring them in".
  defp writable(socket, roster) do
    present = MapSet.new(roster, &to_string/1)

    for id <- campaign_character_ids(socket),
        entry = Library.get(id),
        entry != nil,
        not MapSet.member?(present, to_string(entry.id)),
        match?(%CharacterSheet{status: s} when s != :full, Library.payload(entry)),
        do: entry
  end

  defp campaign_character_ids(socket) do
    with cid when not is_nil(cid) <- campaign_of(socket.assigns.scene_id),
         entry when not is_nil(entry) <- Library.get(cid),
         %{} = payload <- Library.payload(entry) do
      Map.get(payload, :character_ids) || []
    else
      _ -> []
    end
  end

  defp campaign_of(scene_id) do
    case scene_opened(scene_id) do
      %SceneOpened{campaign_id: cid} -> cid
      _ -> nil
    end
  end

  defp scene_opened(scene_id) do
    scene_id
    |> stored_with_seq()
    |> Enum.find_value(fn {_seq, e} -> match?(%SceneOpened{}, e) && e end)
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> nil
    end
  end

  # ── User actions ─────────────────────────────────────────────────────────────

  # Speak as the current viewer character. Aloud vs. whisper is inferred from the text
  # (see `SayParser`), so a single submission can carry both.
  def handle_event("say", %{"text" => text}, socket) do
    # Block player speech while a beat is advancing (defense in depth; the Send button
    # is also disabled) — a mid-beat commit would land in the wrong beat.
    if beat_busy?(socket.assigns.progress) do
      {:noreply, put_flash(socket, :error, "Hold on — the scene is still advancing.")}
    else
      say(socket, text)
    end
  end

  def handle_event("say", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Type something to say.")}

  # ✨ Expand: draft the user's next turn from their character's *filtered* view (§11),
  # seeded by whatever they've typed (expanded/polished) or from scratch if empty. The
  # result is pushed back into the composer to edit before sending — never auto-committed.
  # Give up the slot the walk is waiting on. Only offered while it *is* waiting — a
  # pass outside a paused slot has nothing to pass on, and the beat would carry on
  # without it.
  def handle_event("pass_turn", _params, socket) do
    safe(socket, fn ->
      case awaiting(socket.assigns.progress) do
        {character, beat} ->
          BeatDriver.pass_turn(socket.assigns.scene_id, beat, character)

          {:noreply,
           socket
           |> assign(progress: idle())
           |> reload()
           |> put_flash(:info, "#{name_of(socket, character)} passes.")}

        nil ->
          {:noreply, put_flash(socket, :error, "Nothing is waiting on you.")}
      end
    end)
  end

  def handle_event("compose", %{"text" => draft}, socket) do
    if beat_busy?(socket.assigns.progress) do
      {:noreply, put_flash(socket, :error, "Hold on — the scene is still advancing.")}
    else
      compose(socket, draft)
    end
  end

  def handle_event("view_as", %{"as" => as}, socket) do
    scene_id = socket.assigns.scene_id
    to = if as in [nil, ""], do: ~p"/play/#{scene_id}", else: ~p"/play/#{scene_id}?#{[as: as]}"
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("set_control", %{"character" => character, "control" => control}, socket)
      when control in ~w(autonomous assisted user_controlled) do
    safe(socket, fn ->
      :ok =
        App.dispatch(%SetControlMode{
          scene_id: socket.assigns.scene_id,
          character_id: character,
          control: control
        })

      {:noreply, reload(socket)}
    end)
  end

  def handle_event("retry_failure", %{"id" => id}, socket) do
    safe(socket, fn ->
      case Failures.retry(String.to_integer(id)) do
        {:ok, _} ->
          {:noreply,
           socket |> put_flash(:info, "Retrying…") |> assign(waiting: :director) |> reload()}

        _ ->
          {:noreply, put_flash(socket, :error, "Couldn't retry that.")}
      end
    end)
  end

  # ── Turn management within a beat (§7 supersede-and-recommit) ──────────────────

  # Reroll: regenerate this turn (and the rest of its beat) in place. Async — the
  # generation can be slow — with the busy indicator up.
  def handle_event("reroll_turn", %{"beat" => b, "character" => c}, socket) do
    safe(socket, fn ->
      scene = socket.assigns.scene_id
      beat = String.to_integer(b)

      {:noreply,
       socket
       |> assign(waiting: :director)
       |> put_flash(:info, "Rerolling #{name_of(socket, c)}…")
       |> start_async({:reroll, c}, fn -> Polyphony.Reroll.reroll(scene, beat, c) end)}
    end)
  end

  # Delete: supersede this turn so it drops out of the canonical transcript.
  def handle_event("delete_turn", %{"beat" => b, "character" => c, "packet" => pid}, socket) do
    safe(socket, fn ->
      scene = socket.assigns.scene_id
      beat = String.to_integer(b)
      attempt = BeatOps.next_attempt(BeatOps.stored_events(scene), scene, beat, c)

      :ok =
        App.dispatch(%SupersedePacket{
          scene_id: scene,
          beat: beat,
          character_id: c,
          packet_id: pid,
          attempt: attempt,
          reason: "deleted by author"
        })

      {:noreply, socket |> put_flash(:info, "Removed #{name_of(socket, c)}'s turn.") |> reload()}
    end)
  end

  def handle_event("edit_turn", %{"packet" => pid}, socket),
    do: {:noreply, assign(socket, editing: pid)}

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  # Save an edit: supersede the old take and commit the author's rewrite as a new
  # attempt (same aloud/whisper inference as the composer).
  def handle_event(
        "save_edit",
        %{"beat" => b, "character" => c} = params,
        socket
      ) do
    safe(socket, fn ->
      scene = socket.assigns.scene_id
      beat = String.to_integer(b)

      case TurnEdit.parse(params["text"] || "") do
        {[], _self_state} ->
          {:noreply, put_flash(socket, :error, "The turn can't be empty.")}

        {moves, self_state} ->
          # Through `Edit.edit/6` rather than hand-rolled supersede-and-commit. The
          # module has always known both halves — correct in place, or fork and drop the
          # stale tail — and this screen implemented only the first, so an edit that
          # changed what happened left every turn written on top of it standing.
          corrected =
            Cast.resolve_addressees(
              socket.assigns.cast,
              %TurnPacket{moves: moves, self_state: self_state}
            )

          validity = if params["invalidates"] == "true", do: :invalid, else: :valid

          case Edit.edit(scene, beat, c, corrected, validity, label: "edited at beat #{beat}") do
            {:ok, %{forked: true, scene_id: branch}} ->
              # The branch is where the corrected turn lives, so that is where the
              # author now is. The original is untouched and still reachable by its id.
              {:noreply,
               socket
               |> assign(editing: nil)
               |> put_flash(:info, "Branched here. The original scene is unchanged.")
               |> push_navigate(to: ~p"/play/#{branch}")}

            {:ok, _} ->
              {:noreply,
               socket
               |> assign(editing: nil)
               |> put_flash(:info, "Updated #{name_of(socket, c)}'s turn.")
               |> reload()}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Couldn't edit that turn: #{inspect(reason)}")}
          end
      end
    end)
  end

  # Scan the scene's committed prose for characters mentioned but not yet created,
  # and stub them for later (§B8 mention-stubbing).
  def handle_event("find_mentions", _params, socket) do
    safe(socket, fn ->
      prose = scene_prose(socket.assigns.scene_id)
      uid = socket.assigns.current_user && socket.assigns.current_user.id

      {:noreply,
       socket
       |> put_flash(:info, "Scanning for mentioned characters…")
       |> request_generation("mentions", "play.mentions", %{prose: prose, user_id: uid})}
    end)
  end

  # ── The GM's own moves ────────────────────────────────────────────────────────

  # Narrate: the one thing only the GM writes, because it isn't anybody's turn. It
  # commits a world event at the current beat — the same event the Director emits,
  # from a human instead — so it's visible to every member and reads as fiction.
  def handle_event("narrate_open", _params, socket),
    do: {:noreply, assign(socket, narrating: true, panel: nil)}

  def handle_event("cancel_narrate", _params, socket),
    do: {:noreply, assign(socket, narrating: false, narrating_draft: "")}

  # Keep what's typed in the socket so a ✦ that comes back doesn't discard it — the
  # textarea is uncontrolled, so without this the draft the author has half-written is
  # the thing the expand is supposed to build on and can't see.
  def handle_event("sync_narrate", %{"text" => text}, socket),
    do: {:noreply, assign(socket, narrating_draft: text)}

  # ✦ Expand for the one move that is entirely the author's. The composer has had this
  # since it existed; Narrate is the other thing you can write from that bar and had
  # nothing, which made the Director's own move the only one with no help.
  #
  # Grounded in **what the scene can see**: a world event goes straight into every
  # member's transcript, so seeding the draft with somebody's interior thought or a
  # whisper is how a drafting aid narrates a secret out loud. `Visibility` isn't in this
  # path — `public_lines/1` choosing what to pass is.
  def handle_event("expand_narrate", _params, socket) do
    safe(socket, fn ->
      # Read from the socket, not from the click. A `phx-click` carries `phx-value-*`,
      # not the textarea beside it, and threading the live value through the button
      # means racing `phx-change` against the blur the click itself causes. `sync_narrate`
      # is debounced short for exactly this.
      text = socket.assigns.narrating_draft

      opts =
        [
          world: narration_world(socket),
          cast:
            for(id <- socket.assigns.roster, do: %{"name" => name_of(socket.assigns.cast, id)}),
          location: elem(scene_campaign_location(socket.assigns.scene_id), 1),
          recent: public_lines(socket.assigns.messages),
          current: text
        ] ++ narration_meter(socket)

      {:noreply,
       socket
       |> assign(narrating_draft: text, drafting_narration: true)
       |> request_generation("narrate", "autofill.narration", %{opts: opts})}
    end)
  end

  def handle_event("narrate", %{"text" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, put_flash(socket, :error, "Say what happens.")}

      content ->
        safe(socket, fn ->
          :ok =
            App.dispatch(%RecordWorldEvent{
              scene_id: socket.assigns.scene_id,
              beat: max(socket.assigns.next_beat - 1, 1),
              content: content
            })

          {:noreply, socket |> assign(narrating: false) |> reload()}
        end)
    end
  end

  # The author panels are one-at-a-time: the bottom bar is small, and two open
  # drawers would push the transcript off the screen on a phone.
  # Who is this. The **public** read — the cover — whoever is looking: an author
  # reviewing, a character mid-scene, and a stranger reading a published campaign all
  # get the same card, because the cover is the thing written to be shown (§2.12) and a
  # panel that filtered a sheet per viewer would be a second implementation of a
  # guarantee `Visibility` already owns.
  def handle_event("who", %{"id" => id}, socket) do
    entry = Library.get(normalize_id(id))
    sheet = entry && Library.payload(entry)

    case sheet do
      %CharacterSheet{} -> {:noreply, assign(socket, who: sheet)}
      _ -> {:noreply, put_flash(socket, :error, "Nothing written about them yet.")}
    end
  end

  def handle_event("close_who", _params, socket), do: {:noreply, assign(socket, who: nil)}

  def handle_event("toggle_cast", _params, socket),
    do: {:noreply, assign(socket, panel: toggle(socket.assigns.panel, :cast), narrating: false)}

  # Somebody from the campaign who isn't in this scene yet.
  def handle_event("add_to_scene", %{"id" => id}, socket) do
    safe(socket, fn ->
      entry = Enum.find(socket.assigns.joinable, &(to_string(&1.id) == to_string(id)))

      cond do
        is_nil(entry) ->
          {:noreply, put_flash(socket, :error, "They aren't available to bring in.")}

        true ->
          {:noreply, admit(socket, entry, Library.payload(entry))}
      end
    end)
  end

  # Write a walk-on in and bring them on, in one act. Reuses `play.intro` — the same op
  # an accepted Director introduction takes — so a walk-on the author reached for and
  # one the Director asked for are written the same way and arrive the same way. Keyed
  # by **id** rather than by name: this person already exists, and a name is a display
  # value that two of them can share.
  def handle_event("write_in", %{"id" => id}, socket) do
    safe(socket, fn ->
      entry = Enum.find(socket.assigns.writable, &(to_string(&1.id) == to_string(id)))

      if entry do
        uid = socket.assigns.current_user && socket.assigns.current_user.id

        {:noreply,
         socket
         |> assign(writing_in: MapSet.put(socket.assigns.writing_in, entry.id))
         |> request_generation("write_in:#{entry.id}", "play.intro", %{
           entry_id: entry.id,
           user_id: uid
         })}
      else
        {:noreply, put_flash(socket, :error, "They aren't waiting to be written.")}
      end
    end)
  end

  def handle_event("toggle_intros", _params, socket),
    do: {:noreply, assign(socket, panel: toggle(socket.assigns.panel, :intros), narrating: false)}

  def handle_event("continue", _params, socket) do
    cond do
      beat_busy?(socket.assigns.progress) ->
        {:noreply, put_flash(socket, :error, "The scene is already advancing.")}

      socket.assigns.roster == [] ->
        {:noreply, put_flash(socket, :error, "No cast present to continue with.")}

      true ->
        safe(socket, fn ->
          scene_id = socket.assigns.scene_id
          beat = socket.assigns.next_beat
          roster = socket.assigns.roster

          # Declare the beat's turn order (roster order), then let the Oban Director loop
          # cast the autonomous members. Events stream back over the broadcaster.
          :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene_id, beat: beat, order: roster})
          SceneControl.continue(scene_id, beat, args: %{"control_hint" => "yield_to_user"})
          # Optimistically show "director" immediately; the job's own announces refine it
          # (which character is generating) and clear it on settle.
          {:noreply,
           socket
           |> assign(progress: %{phase: :director, subject: nil}, next_beat: beat + 1)}
        end)
    end
  end

  # ── Director introductions (resolve the pending queue) ─────────────────────────

  # ── Assisted drafts (§A2) ────────────────────────────────────────────────────
  #
  # The half of §1.5 that was deferred: the backend has committed and discarded
  # drafts since it shipped, and nothing on screen ever showed one — press Continue
  # on a character set to draft-and-approve and the beat simply stopped, with the
  # turn sitting in a table.

  def handle_event("accept_draft", %{"id" => id}, socket) do
    safe(socket, fn ->
      case BeatDriver.accept_draft(String.to_integer(id)) do
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Couldn't take that turn: #{inspect(reason)}")}

        _ ->
          {:noreply, socket |> reload() |> put_flash(:info, "Taken.")}
      end
    end)
  end

  def handle_event("edit_draft", %{"id" => id}, socket),
    do: {:noreply, assign(socket, editing_draft: String.to_integer(id))}

  def handle_event("cancel_draft_edit", _params, socket),
    do: {:noreply, assign(socket, editing_draft: nil)}

  # Correct a draft before taking it. `Drafts.edit/3` has always been able to do this
  # and nothing called it, so the card could only take a turn whole or throw it away —
  # and a turn that is nearly right is the ordinary case, which is the entire argument
  # for approving one rather than letting it commit.
  def handle_event("save_draft_edit", %{"draft_id" => id} = params, socket) do
    safe(socket, fn ->
      case TurnEdit.parse(params["text"] || "") do
        {[], _self_state} ->
          {:noreply, put_flash(socket, :error, "The turn can't be empty.")}

        {moves, self_state} ->
          corrected =
            Cast.resolve_addressees(
              socket.assigns.cast,
              %TurnPacket{moves: moves, self_state: self_state}
            )

          Drafts.edit(String.to_integer(id), corrected)
          {:noreply, socket |> assign(editing_draft: nil) |> reload()}
      end
    end)
  end

  def handle_event("discard_draft", %{"id" => id}, socket) do
    safe(socket, fn ->
      case BeatDriver.discard_draft(String.to_integer(id)) do
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Couldn't discard that: #{inspect(reason)}")}

        _ ->
          {:noreply, socket |> reload() |> put_flash(:info, "Discarded — they pass.")}
      end
    end)
  end

  def handle_event("intro_admit", %{"name" => name}, socket) do
    safe(socket, fn ->
      case find_owned(socket, name) do
        {:full, entry} ->
          {:noreply, admit(socket, entry, Library.payload(entry))}

        _ ->
          {:noreply,
           put_flash(socket, :error, "#{name} isn't ready — generate or edit them first.")}
      end
    end)
  end

  def handle_event("intro_dismiss", %{"name" => name}, socket) do
    safe(socket, fn ->
      :ok = App.dispatch(%DismissIntroduction{scene_id: socket.assigns.scene_id, name: name})
      {:noreply, reload(socket)}
    end)
  end

  def handle_event("intro_edit", %{"name" => name}, socket) do
    safe(socket, fn ->
      entry = ensure_character(socket, name)
      {:noreply, push_navigate(socket, to: ~p"/authoring/character/#{entry.id}")}
    end)
  end

  def handle_event("intro_generate", %{"name" => name}, socket) do
    safe(socket, fn ->
      entry = ensure_character(socket, name)
      uid = socket.assigns.current_user && socket.assigns.current_user.id

      {:noreply,
       socket
       |> put_flash(:info, "Generating #{name}…")
       |> request_generation("intro:#{name}", "play.intro", %{
         entry_id: entry.id,
         user_id: uid
       })}
    end)
  end

  # ── Live events ──────────────────────────────────────────────────────────────

  # A draft landed. The beat has stopped and is waiting on a decision, so stop
  # showing it as in-flight — otherwise the composer stays blocked behind a spinner
  # for a beat that isn't going anywhere on its own.
  def handle_info({:polyphony_event, %{type: "draft.ready"}}, socket) do
    {:noreply, socket |> assign(progress: idle()) |> reload()}
  end

  def handle_info({:polyphony_event, %{type: "generation.failed"}}, socket) do
    # A turn couldn't be generated — stop waiting and surface the open failure
    # (reload picks it up from the Failures store) instead of failing silently.
    {:noreply, socket |> assign(waiting: :you, progress: idle()) |> reload()}
  end

  # Beat-loop activity: reflect what's running now (Director / a character / idle) so the
  # indicator is accurate and input stays blocked until the beat truly settles.
  def handle_info({:scene_progress, %{phase: phase} = p}, socket) do
    # The beat comes with it and used to be dropped. `submit_user_turn/5` needs the beat
    # the walk actually paused on — committing at `next_beat` instead is how a
    # user-controlled turn lands outside the beat that is waiting for it.
    {:noreply, assign(socket, progress: %{phase: phase, subject: p[:subject], beat: p[:beat]})}
  end

  def handle_info({:polyphony_event, %{type: "packet.superseded"}}, socket) do
    # A re-roll/edit/delete dropped a packet — re-derive canonical rather than append.
    {:noreply, reload(socket)}
  end

  def handle_info({:polyphony_event, msg}, socket) do
    socket =
      case msg do
        %{kind: "BeatClosed"} -> assign(socket, waiting: :you)
        _ -> socket
      end

    {:noreply, append(socket, msg)}
  end

  # Debug drawer toggled a scene-pane view — reflect it (reload so the data is fresh).
  def handle_info({:debug_flag, :events, value}, socket),
    do: {:noreply, socket |> assign(debug_events: value) |> reload()}

  def handle_info({:debug_flag, :trace, value}, socket),
    do: {:noreply, socket |> assign(debug_trace: value) |> reload()}

  def handle_info({:debug_flag, _flag, _value}, socket), do: {:noreply, socket}

  # A new LLM request/response was captured for this scene — refresh the trace list.
  def handle_info({:debug_trace, _scene_id}, socket) do
    if socket.assigns.debug_trace do
      {:noreply, assign(socket, traces: DebugTap.recent(socket.assigns.scene_id))}
    else
      {:noreply, socket}
    end
  end

  # A just-generated introduction is now :full — admit them.
  def handle_info({:generation, "narrate", {:ok, text}}, socket) do
    {:noreply,
     socket
     |> forget_generation("narrate")
     |> assign(drafting_narration: false, narrating: true, narrating_draft: text)}
  end

  def handle_info({:generation, "narrate", result}, socket) do
    Logger.warning("[play] narration draft failed: #{inspect(result)}")

    {:noreply,
     socket
     |> forget_generation("narrate")
     |> assign(drafting_narration: false)
     |> put_flash(:error, "Couldn't draft that — write it yourself, or try again.")}
  end

  def handle_info({:generation, "write_in:" <> id, {:ok, _}}, socket) do
    safe(socket, fn ->
      socket =
        socket
        |> forget_generation("write_in:#{id}")
        |> assign(writing_in: MapSet.delete(socket.assigns.writing_in, normalize_id(id)))

      case Library.get(normalize_id(id)) do
        nil ->
          {:noreply, put_flash(socket, :error, "They're gone.")}

        entry ->
          sheet = Library.payload(entry)

          # `admit/3` refuses a non-`:full` character the same way `SceneControl` does,
          # so the check is here rather than trusted: a generation that came back
          # `{:ok, _}` having written nothing usable must not be walked on stage.
          if match?(%CharacterSheet{status: :full}, sheet) do
            {:noreply, admit(socket, entry, sheet)}
          else
            {:noreply, put_flash(socket, :error, "Written, but not ready — open them to finish.")}
          end
      end
    end)
  end

  def handle_info({:generation, "write_in:" <> id, result}, socket) do
    Logger.warning("[play] write-in failed for #{id}: #{inspect(result)}")

    {:noreply,
     socket
     |> forget_generation("write_in:#{id}")
     |> assign(writing_in: MapSet.delete(socket.assigns.writing_in, normalize_id(id)))
     |> put_flash(:error, "Couldn't write them — open them to finish by hand.")}
  end

  def handle_info({:generation, "intro:" <> name, {:ok, _}}, socket) do
    safe(socket, fn ->
      case find_owned(socket, name) do
        {:full, entry} ->
          {:noreply, admit(socket, entry, Library.payload(entry))}

        _ ->
          {:noreply,
           put_flash(socket, :error, "Generated #{name}, but they're not ready — open them.")}
      end
    end)
  end

  def handle_info({:generation, "intro:" <> name, _result}, socket) do
    {:noreply,
     socket
     |> forget_generation("intro:#{name}")
     |> put_flash(:error, "Couldn't generate #{name} — open them to finish manually.")}
  end

  def handle_info({:generation, "mentions", {:ok, names}}, socket) do
    safe(socket, fn ->
      case stub_mentions(socket, names) do
        [] ->
          {:noreply, put_flash(socket, :info, "No new characters were mentioned.")}

        stubbed ->
          {:noreply,
           put_flash(
             socket,
             :info,
             "Stubbed #{length(stubbed)} mentioned character(s): #{Enum.join(stubbed, ", ")}."
           )}
      end
    end)
  end

  def handle_info({:generation, "mentions", _result}, socket),
    do:
      {:noreply,
       socket
       |> forget_generation("mentions")
       |> put_flash(:error, "Couldn't scan for mentioned characters.")}

  def handle_info({:generation, "compose", {:ok, [packet | _]}}, socket) do
    text = TurnEdit.serialize_packet(packet)

    {:noreply,
     socket
     |> forget_generation("compose")
     |> assign(composing: false)
     |> push_event("set_composer", %{text: text})}
  end

  def handle_info({:generation, "compose", {:error, reason}}, socket) do
    {:noreply,
     socket
     |> forget_generation("compose")
     |> assign(composing: false)
     |> put_flash(:error, compose_error(reason))}
  end

  def handle_info({:generation, "compose", _result}, socket) do
    {:noreply,
     socket
     |> forget_generation("compose")
     |> assign(composing: false)
     |> put_flash(:error, "Couldn't draft a turn. Try again.")}
  end

  # Commit the player's typed turn (§A1). Grouped here (not among the handle_events) so
  # the two "say" clauses stay adjacent.

  def handle_info(_other, socket), do: {:noreply, socket}

  # The reroll is the one generation still on a plain task, and deliberately: it
  # supersedes a packet and enqueues `Jobs.GeneratePacket`, so what actually generates
  # has always been a job and the replacement arrives on the transcript stream. What the
  # task does is dispatch, which is fast and idempotent to lose.
  def handle_async({:reroll, _c}, {:ok, {:ok, _}}, socket),
    do: {:noreply, socket |> assign(waiting: :you) |> reload()}

  def handle_async({:reroll, c}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(waiting: :you)
     |> put_flash(:error, "Couldn't reroll #{c} (#{inspect(reason)}).")
     |> reload()}
  end

  def handle_async({:reroll, c}, _result, socket) do
    {:noreply, socket |> assign(waiting: :you) |> put_flash(:error, "Reroll of #{c} failed.")}
  end

  defp say(socket, text) do
    safe(socket, fn ->
      # The composer parses the whole turn (speech + whisper, plus thinks:/does: from
      # an expanded draft), same format as the transcript's turn editor (`TurnEdit`).
      case {socket.assigns.speaker, TurnEdit.parse(text)} do
        {nil, _} ->
          {:noreply, put_flash(socket, :error, "Switch to a character above to speak.")}

        {_as, {[], _self_state}} ->
          {:noreply, put_flash(socket, :error, "Type something to say.")}

        {as, {moves, self_state}} ->
          # The player types "(whisper to Bram: …)" — a name. `addressed_to` is the
          # routing key visibility matches on, so resolve it to an id here, at the
          # last moment before the packet becomes a fact in the log (§5.2).
          packet =
            Cast.resolve_addressees(
              socket.assigns.cast,
              %TurnPacket{moves: moves, self_state: self_state}
            )

          {:noreply, take_turn(socket, as, packet)}
      end
    end)
  end

  # Two ways a turn reaches the log, and which one applies is not a preference.
  #
  # If the beat loop has **paused on this character's slot** (`user_controlled`, §A1),
  # the turn belongs to that slot: `submit_user_turn/5` commits it against the paused
  # beat, records the packet on the beat aggregate, and walks the Director on. Skipping
  # that is what made "I write their turns" inert — the composer committed a free packet
  # at `next_beat`, so the walk stayed paused and the Director wrote the same character
  # a second time when it resumed.
  #
  # Otherwise nothing is waiting and this is the author speaking into the next beat,
  # which is the original behaviour and still the right one for a scene nobody has
  # pressed Continue on.
  defp take_turn(socket, as, packet) do
    case awaiting(socket.assigns.progress) do
      {^as, beat} ->
        BeatDriver.submit_user_turn(socket.assigns.scene_id, beat, as, packet)
        socket |> assign(progress: idle()) |> reload()

      _ ->
        beat = socket.assigns.next_beat

        :ok =
          App.dispatch(%CommitPacket{
            scene_id: socket.assigns.scene_id,
            character_id: as,
            beat: beat,
            packet_id: BeatOps.packet_id(socket.assigns.scene_id, beat, as),
            packet: packet,
            edited: true
          })

        socket |> assign(next_beat: beat + 1) |> reload()
    end
  end

  # Kick off the async Expand draft (§11) for the acting character, from their sheet +
  # filtered view. Grouped here (not among the handle_events) to keep the clauses tidy.
  defp compose(socket, draft) do
    safe(socket, fn ->
      case socket.assigns.speaker do
        nil ->
          {:noreply, put_flash(socket, :error, "Switch to a character above to speak.")}

        as ->
          scene_id = socket.assigns.scene_id
          roster = socket.assigns.roster
          user = socket.assigns.current_user
          premise = socket.assigns.premise
          sheet = character_sheet(socket, as)
          bible = campaign_world_bible(socket)

          {:noreply,
           socket
           |> assign(composing: true)
           |> request_generation("compose", "play.compose", %{
             opts: compose_opts(scene_id, as, sheet, premise, bible, roster, draft, user)
           })}
      end
    end)
  end

  # A human, specific message for an Expand failure, mapped from the underlying
  # generation error (surfaced through `Suggest.variants`) — so the player knows whether
  # to retry, edit, or wait, instead of a blanket "couldn't draft".
  defp compose_error({:no_variants, reason}), do: compose_error(reason)

  defp compose_error({:provider, {:http_status, 429, _}}),
    do: "The model is busy right now (rate-limited). Give it a moment and hit Expand again."

  defp compose_error({:provider, {:http_status, status, _}}),
    do: "The model returned an error (HTTP #{status}). Try Expand again."

  defp compose_error({:provider, {:transport, :timeout}}),
    do: "The draft timed out before the model responded. Try Expand again."

  defp compose_error({:provider, {:transport, reason}}),
    do: "Couldn't reach the model (#{short_reason(reason)}). Try Expand again."

  defp compose_error({:provider, :cost_cap_reached}), do: cost_cap_message()
  defp compose_error(:cost_cap_reached), do: cost_cap_message()

  defp compose_error({:refusal, _}),
    do:
      "The model declined to write this turn. Edit your draft or the character's setup, then try again."

  defp compose_error({:empty_response, _}),
    do: "The model returned an empty response. Hit Expand again — this usually clears on a retry."

  defp compose_error({:schema_invalid, _}),
    do: "The draft didn't match the required format after a couple of tries. Hit Expand again."

  defp compose_error(other), do: "Couldn't draft a turn: #{short_reason(other)}. Try again."

  defp cost_cap_message,
    do: "You've hit the spending cap for this campaign — raise it in settings to keep generating."

  # A compact, flash-safe rendering of an arbitrary error term (a 429 body or a stacktrace
  # can be huge).
  defp short_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 160)
  defp short_reason(reason), do: reason |> inspect() |> String.slice(0, 160)

  # Draft a turn from the character's filtered view (§11) — steered by the player's
  # partial text if any, else generated fresh. Never omniscient (a suggestion can't
  # react to something the character never learned).
  defp compose_opts(scene_id, character, sheet, premise, bible, roster, draft, user) do
    ctx = character_context(scene_id, character, sheet, premise, bible)

    [
      context: ctx,
      live_events: BeatOps.canonical_events(scene_id),
      members: roster,
      count: 1,
      steer: compose_steer(draft),
      user_id: user && user.id,
      usage_kind: "suggestion"
    ]
  end

  # The character's frozen context — from the cache, or **rebuilt and re-cached on a
  # miss**. The ETS cache is cold after a restart (it's pure cache, rebuildable from
  # the sheet + log), so a miss must not fail the draft.
  defp character_context(scene_id, character, sheet, premise, bible) do
    case Store.fetch(scene_id, character) do
      {:ok, ctx} ->
        ctx

      :error ->
        {campaign_id, location} = scene_campaign_location(scene_id)

        ctx =
          Context.materialize(
            scene_id: scene_id,
            character_id: character,
            # Canon character + world arc folded in (§2.8), scoped to this location.
            sheet: Effective.sheet(sheet, character),
            premise: premise,
            world_bible: Effective.world_bible(bible, campaign_id, location),
            retriever: PgvectorRetriever
          )

        Store.put(scene_id, character, ctx)
        ctx
    end
  end

  # The scene's campaign + authored location, from its opening event (durable) — used
  # to fold canon world arc into the world half of context, scoped to this place.
  defp scene_campaign_location(scene_id) do
    case Rebuild.opened(scene_id) do
      %SceneOpened{campaign_id: c, location_id: l} -> {c, l}
      _ -> {nil, nil}
    end
  end

  # The acting character's sheet, resolved through `Rebuild.sheet_for/2`: the **id**
  # they entered the scene under first (§5.2 — the lookup a rename used to break),
  # then the legacy name match, so a scene keyed by names still drafts. Falls back to
  # a name-only sheet when nothing resolves, so Expand still works for a character
  # without one.
  defp character_sheet(socket, character_id) do
    case Rebuild.sheet_for(socket.assigns.scene_id, character_id) do
      %CharacterSheet{} = sheet -> sheet
      _ -> %CharacterSheet{name: name_of(socket, character_id)}
    end
  end

  defp compose_steer(draft) do
    case String.trim(to_string(draft || "")) do
      "" ->
        "Write a natural next turn for this character from scratch."

      text ->
        "The player sketched this draft — expand and polish it into a full, in-character " <>
          "turn, keeping their intent and any specifics:\n\n" <> text
    end
  end

  defp append(socket, msg) do
    seq = msg[:seq]
    existing = socket.assigns.messages

    if is_integer(seq) and Enum.any?(existing, &(&1[:seq] == seq)) do
      socket
    else
      assign(socket, messages: existing ++ [msg])
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp stored_with_seq(scene_id) do
    case Commanded.EventStore.stream_forward(App, scene_id) do
      {:error, _} -> []
      stream -> stream |> Enum.map(fn e -> {e.stream_version, e.data} end)
    end
  end

  defp event_beat(%{beat: b}) when is_integer(b), do: b
  defp event_beat(_), do: 0

  # ── Debug timeline (author-only) ─────────────────────────────────────────────
  #
  # LLM calls, raw events, and errors interleaved on one wall-clock timeline so the
  # author can read *what happened when*. Built only for the omniscient view with a
  # debug pane on; each source is gated on its own toggle, and errors ride along
  # whenever the pane is open. Oldest → newest (matches the transcript's autoscroll).

  defp debug_feed(socket, traces, failures) do
    if socket.assigns.viewer == :omniscient and
         (socket.assigns.debug_events or socket.assigns.debug_trace) do
      events =
        if socket.assigns.debug_events, do: event_feed_items(socket.assigns.scene_id), else: []

      calls = if socket.assigns.debug_trace, do: trace_feed_items(traces), else: []
      errors = error_feed_items(failures)

      Enum.sort_by(events ++ calls ++ errors, & &1.at_ms)
    else
      []
    end
  end

  defp event_feed_items(scene_id) do
    scene_id
    |> stored_recorded()
    |> Enum.map(fn {seq, e, at} ->
      %{
        kind: :event,
        at_ms: to_ms(at),
        seq: seq,
        beat: event_beat(e),
        label: debug_kind(e),
        detail: debug_detail(e)
      }
    end)
  end

  defp trace_feed_items(traces) do
    Enum.map(traces, fn t ->
      %{
        kind: :trace,
        at_ms: to_ms(Map.get(t, :at)),
        subject: t.subject,
        model: trace_model(t.params),
        outcome: trace_outcome(t.response),
        params: inspect(t.params),
        request: trace_request(t.request),
        response: trace_response(t.response),
        is_error: match?({:error, _}, t.response)
      }
    end)
  end

  defp error_feed_items(failures) do
    Enum.map(failures, fn f ->
      %{
        kind: :error,
        at_ms: to_ms(Map.get(f, :inserted_at)),
        subject: f.subject || "a turn",
        beat: f.beat,
        detail: failure_reason(f)
      }
    end)
  end

  # Read the scene stream keeping each event's log position and wall-clock stamp — the
  # extra axis the interleaved timeline sorts on (prod's EventStore stamps `created_at`).
  defp stored_recorded(scene_id) do
    case Commanded.EventStore.stream_forward(App, scene_id) do
      {:error, _} -> []
      stream -> Enum.map(stream, fn e -> {e.stream_version, e.data, Map.get(e, :created_at)} end)
    end
  end

  # Normalize every source's timestamp to unix-ms for one comparable sort key; a missing
  # stamp sorts to the front (stable sort keeps such items in their source order).
  defp to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp to_ms(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp to_ms(ms) when is_integer(ms), do: ms
  defp to_ms(_), do: 0

  # A compact HH:MM:SS (UTC) label for a timeline entry.
  defp at_label(ms) when is_integer(ms) and ms > 0,
    do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")

  defp at_label(_), do: "—"

  # A plain-text rendering of the whole timeline, stashed hidden for the Copy button so
  # collapsed <details> content comes along too (paste-to-report friendly).
  defp feed_text(feed), do: Enum.map_join(feed, "\n\n", &entry_text/1)

  defp entry_text(%{kind: :event} = e),
    do: "[#{at_label(e.at_ms)}] EVENT ##{e.seq} b#{e.beat} #{e.label}\n#{e.detail}"

  defp entry_text(%{kind: :trace} = t),
    do:
      "[#{at_label(t.at_ms)}] LLM #{t.subject} · #{t.model} · #{t.outcome}\n" <>
        "params: #{t.params}\nrequest:\n#{t.request}\nresponse:\n#{t.response}"

  defp entry_text(%{kind: :error} = e),
    do: "[#{at_label(e.at_ms)}] ERROR #{e.subject} b#{e.beat}\n#{e.detail}"

  # Debug view (author-only): the event's struct name and a compact dump of its fields.
  defp debug_kind(e) when is_struct(e), do: e.__struct__ |> Module.split() |> List.last()
  defp debug_kind(_), do: "?"

  defp debug_detail(e) when is_struct(e) do
    e
    |> Map.from_struct()
    |> Map.drop([:scene_id, :beat])
    |> inspect(pretty: false, limit: 12, printable_limit: 240)
    |> String.slice(0, 400)
  end

  defp debug_detail(other), do: inspect(other)

  # LLM trace rendering (author debug pane).
  defp trace_model(params), do: to_string(params[:model] || "workhorse")

  defp trace_outcome({:ok, _}), do: "ok"
  defp trace_outcome({:error, reason}), do: "ERROR #{inspect(reason)}"
  defp trace_outcome(_), do: "?"

  defp trace_request(messages) when is_list(messages) do
    Enum.map_join(messages, "\n\n", fn m ->
      "[#{m[:role] || m["role"]}]\n#{m[:content] || m["content"]}"
    end)
  end

  defp trace_request(other), do: inspect(other)

  defp trace_response({:ok, text}), do: text
  defp trace_response({:error, reason}), do: "ERROR: " <> inspect(reason)
  defp trace_response(other), do: inspect(other)

  defp toggle(current, panel), do: if(current == panel, do: nil, else: panel)

  # A character's control mode, defaulting to autonomous (matches the beat walk).
  defp control_of(modes, character), do: Map.get(modes, character) || "autonomous"

  # ── Names (§5.2) ──────────────────────────────────────────────────────────────
  #
  # The single edge between the id-keyed log and the name-keyed fiction. Every
  # human-facing string on this page goes through here; nothing that routes does.

  # Tapping a slot puts you behind that person's eyes — the same move the perspective
  # picker makes, so it goes the same way: a patch on `?as=`, which `handle_params/3`
  # already resolves. Only for someone the scene actually knows, since a slot can carry
  # a name the log mentioned and the cast has never held, and never for the perspective
  # you are already in.
  defp slot_view(%{id: id}, %Cast{} = cast, scene_id, viewer) when is_binary(id) do
    if Map.has_key?(cast.id_to_name, id) and viewer != {:character, id},
      do: ~p"/play/#{scene_id}?#{[as: id]}"
  end

  defp slot_view(_slot, _cast, _scene_id, _viewer), do: nil

  defp name_of(%{assigns: %{cast: cast}}, id), do: Cast.render_name(cast, id)
  defp name_of(%Cast{} = cast, id), do: Cast.render_name(cast, id)
  defp name_of(_socket, id), do: to_string(id)

  # Group the flat message stream into blocks: a character's turn (one committed
  # packet, all its moves) carries edit/reroll/delete affordances; everything else
  # (world events, entrances) is a plain block.
  # The transcript as an ordered list of `{:block, block}` and `{:fail, failure}` items,
  # each failure placed at the beat it occurred (after that beat's turns) rather than in a
  # standalone pane — so a transient error and its Retry sit where they happened and vanish
  # when retried. Event blocks (no beat of their own) inherit the last turn's beat so they
  # keep their place.
  #
  # A failure without a beat is a scene-close operation (arc extraction, summarization);
  # those are emitted at the scene's current beat, so they default to `current_beat` and
  # land with the latest action rather than at the top. A character viewer only ever gets
  # their own turn failures (§1.7), which always carry a beat, so they sort in place.
  defp transcript_items(messages, failures, current_beat) do
    # Blocking and beat rules live in `PolyphonyWeb.Transcript`, shared with the
    # published reading view — the reading view *is* this screen with a different
    # bottom bar, and a second implementation of prose rendering is how the two drift.
    blocks = Transcript.blocks(messages)
    items = Enum.map(blocks, &{:block, &1}) ++ Enum.map(failures, &{:fail, &1})

    items
    |> Enum.sort_by(fn
      {:block, b} -> {b.eff_beat, 0}
      {:fail, f} -> {f.beat || current_beat, 1}
    end)
    |> mark_beat_rules()
  end

  # A beat rule opens a beat exactly once, so it's decided by walking the *sorted*
  # items — which is why this stays here rather than in the shared module: play
  # interleaves failures with turns, and a rule must open above whichever came first.
  defp mark_beat_rules(items) do
    {marked, _} =
      Enum.map_reduce(items, nil, fn
        {:block, b} = item, previous ->
          beat = b.eff_beat

          if is_integer(beat) and beat > 0 and beat != previous do
            {{:block, Map.put(b, :beat_rule, beat)}, beat}
          else
            {item, previous}
          end

        item, previous ->
          {item, previous}
      end)

    marked
  end

  # The editable text of a turn: the whole turn — thoughts, speech, actions, and
  # demeanor — serialized one move per line (see `TurnEdit`), not just its spoken lines.
  defp turn_text(block, cast),
    do: TurnEdit.serialize(block.msgs, &Cast.render_name(cast, &1))

  # The draft's own moves, put through the same serializer the transcript editor uses —
  # so a draft reads, and edits, exactly like the turn it is about to become.
  defp draft_text(draft, cast),
    do:
      draft
      |> draft_moves(draft.row.character_id)
      |> TurnEdit.serialize(&Cast.render_name(cast, &1))

  # ── Beat-loop progress ─────────────────────────────────────────────────────────

  defp idle, do: %{phase: :idle, subject: nil, beat: nil}

  # The beat loop has walked to a `user_controlled` slot and stopped there (§A1). Until
  # this was read, the composer always did a *free* `CommitPacket` at `next_beat`: the
  # walk stayed paused forever, and speaking as a character the Director also drives
  # produced two turns for one slot.
  defp awaiting(%{phase: :awaiting_user, subject: c, beat: b})
       when is_binary(c) and c != "" and is_integer(b),
       do: {c, b}

  defp awaiting(_progress), do: nil

  # Is the composer's current speaker the one the walk is waiting on? Takes the render
  # assigns, not the socket — inside `~H` those are the bare map.
  defp your_slot?(%{progress: progress, speaker: speaker}) when is_binary(speaker) do
    match?({^speaker, _beat}, awaiting(progress))
  end

  defp your_slot?(_assigns), do: false

  # "Busy" for the sake of blocking input: a beat is actively running (the Director is
  # deciding, or a character is generating). `:awaiting_user` is *not* busy — that's the
  # user's own slot — and `:idle` means the loop has settled.
  defp beat_busy?(%{phase: phase}), do: phase in [:director, :generating]
  defp beat_busy?(_), do: false

  # The broadcaster announces a subject by character id (§5.2); the player reads a name.
  defp progress_label(%{phase: :director}, _cast), do: "The director is setting the scene…"

  defp progress_label(%{phase: :generating, subject: c}, cast) when is_binary(c) and c != "",
    do: "#{Cast.render_name(cast, c)} is writing their turn…"

  defp progress_label(%{phase: :generating}, _cast), do: "A character is writing their turn…"

  defp progress_label(%{phase: :awaiting_user, subject: c}, cast) when is_binary(c) and c != "",
    do: "Waiting for you to write #{Cast.render_name(cast, c)}…"

  defp progress_label(_, _cast), do: "Working…"

  # The two things the loop can be doing, each drawn as the move it is about to become:
  # the Director's is `m-world`'s rules-above-and-below, a character's is the
  # voice-coloured rule they will speak inside. Getting this wrong — one generic
  # placeholder for both — would make the transcript reflow the moment the real move
  # arrived, which is the jump the placeholder exists to prevent.
  attr(:progress, :map, required: true)
  attr(:cast, :any, required: true)
  attr(:voices, :map, required: true)

  defp writing_move(%{progress: %{phase: :director}} = assigns) do
    ~H"""
    <Kit.world_move class="my-3">
      <Kit.skel_lines lines={["96%", "72%"]} label="The Director is setting the scene" />
    </Kit.world_move>
    """
  end

  defp writing_move(assigns) do
    assigns =
      assign(assigns,
        subject: generating_now(assigns.progress),
        label: progress_label(assigns.progress, assigns.cast)
      )

    ~H"""
    <Kit.writing
      class="my-3"
      colour={Voice.of(@voices, @subject)}
      note={@label}
      lines={["100%", "88%", "55%"]}
    />
    """
  end

  # A short, human reason for a failure line — the model's reason if any, else the kind.
  defp failure_reason(%{reason: r}) when is_binary(r) and r != "", do: r
  defp failure_reason(%{kind: k}) when is_binary(k) and k != "", do: String.replace(k, "_", " ")
  defp failure_reason(_), do: "generation failed"

  # ── Render ─────────────────────────────────────────────────────────────────────
  #
  # Ported from `ux/polyphony-play.html`. The register is the outer decision: a
  # character viewer gets `.page` (reading — wide measure, prose, machinery at the
  # edges) and the omniscient author gets `.stage` (working — gutter labels and the
  # editorial layer). Same components, same tokens, different density.
  #
  # The stage register has **no composer**, by design: to write a character you
  # become them. The GM's bottom bar is Narrate / Introductions / Continue instead,
  # and the strip's sentence is the way across — it names who is waiting to be
  # written.

  def render(assigns) do
    ~H"""
    <Kit.frame
      register={@register}
      class="flex flex-col min-h-0"
      style="height:100dvh"
    >
      <%!-- The kit's standard header: context small, the scene's location as the
            title, perspective control top right, overflow last. --%>
      <Kit.header title={@scene_title} eyebrow={@campaign_name}>
        <:actions>
          <form id="viewer-form" phx-change="view_as">
            <Kit.viewas_select
              id="viewer-select"
              label="Viewing as"
              name="as"
              colour={viewer_colour(@viewer, @voices)}
            >
              <option value="" selected={@viewer == :omniscient}>Omniscient</option>
              <option :for={c <- @roster} value={c} selected={@viewer == {:character, c}}><%= name_of(@cast, c) %></option>
            </Kit.viewas_select>
          </form>
          <Layouts.nav_menu current_user={@current_user} />
        </:actions>
      </Kit.header>

      <%!-- Connection. Silent when healthy: a permanent "everything is fine" light is
            noise and trains people to stop reading the one place that matters. These
            are driven by the classes LiveView puts on the container, so they need no
            server state — and because reconnecting replays the canonical scene, the
            copy can promise recovery. --%>
      <div
        class="hidden [.phx-loading_&]:flex items-center gap-2 px-4 py-2 row"
        style="background:color-mix(in srgb,var(--lamp) 12%,transparent)"
      >
        <Kit.dot colour="var(--lamp)" />
        <span class="text-[12.5px]">Reconnecting — you won't lose the scene.</span>
      </div>
      <div
        class="hidden [.phx-error_&]:flex items-center gap-2 px-4 py-2 row"
        style="background:color-mix(in srgb,var(--pencil) 12%,transparent)"
      >
        <Kit.dot colour="var(--pencil)" />
        <span class="text-[12.5px]">No connection. The scene will catch up when you're back.</span>
      </div>

      <div :if={@viewer == :omniscient and (@debug_events or @debug_trace)} class="px-4">
        <div class="dbg-head dim flex items-center gap-2 py-2">
          <span>Debug timeline — <%= length(@debug_feed) %> entries</span>
          <Kit.btn
            id="scene-debug-copy-btn"
            kind={:ghost}
            size={:sm}
            type="button"
            phx-hook="CopyText"
            data-copy-target="scene-debug-copy"
          >
            Copy
          </Kit.btn>
        </div>
        <pre id="scene-debug-copy" hidden><%= @debug_feed_text %></pre>
      </div>

      <%!-- Only the transcript scrolls: the header, the strip and the bottom bar hold
            their places, which is what makes the strip "always visible". The kit's
            `.scroller` is a panel height (520px) and would fight that, so the fill is
            done with utilities and the transcript keeps its own scrollbar. --%>
      <div id="transcript" class="flex-1 min-h-0 overflow-y-auto px-4" phx-hook="Autoscroll">
        <%= if @viewer == :omniscient and (@debug_events or @debug_trace) do %>
          <div id="debug-timeline">
            <div :for={entry <- @debug_feed} class={"dbg-entry dbg-#{entry.kind}"}>
              <%= render_debug_entry(entry) %>
            </div>
          </div>
        <% else %>
          <%= for {item, i} <- Enum.with_index(transcript_items(@messages, @failures, max(@next_beat - 1, 0))) do %>
            <%= case item do %>
              <% {:block, block} -> %>
                <.turn_block
                  id={"blk-#{i}"}
                  block={block}
                  register={@register}
                  cast={@cast}
                  voices={@voices}
                  beat_rule={block[:beat_rule]}
                  editable={@viewer == :omniscient and block.type == :turn}
                  editing={@editing}
                  control={control_of(@control_modes, block.character)}
                />
              <% {:fail, f} -> %>
                <Kit.fail_move
                  id={"fail-#{i}"}
                  class="my-3"
                  title={"#{if f.subject, do: name_of(@cast, f.subject), else: "A turn"} didn't generate"}
                  detail={failure_reason(f)}
                >
                  <div :if={f.retryable} class="flex flex-wrap gap-0.5 mt-1.5 -ml-1">
                    <Kit.btn kind={:pen} phx-click="retry_failure" phx-value-id={f.id}>Retry</Kit.btn>
                  </div>
                </Kit.fail_move>
            <% end %>
          <% end %>
          <Kit.empty
            :if={@messages == [] and @failures == [] and not beat_busy?(@progress)}
            headline={empty_headline(@viewer)}
          >
            Nothing has happened here yet.
          </Kit.empty>

          <%!-- The turn being written, where it will land. The strip's waiting line
                says *that* something is happening; this says who, and puts it at the
                bottom of the transcript the reader is already looking at — which is
                also where the words will appear, so nothing jumps when they do.

                A first beat used to be the worst case: an empty scene, an empty-state
                headline saying nothing has happened here yet, and the only sign of
                life a sentence in a bar below the fold. --%>
          <.writing_move
            :if={beat_busy?(@progress)}
            progress={@progress}
            cast={@cast}
            voices={@voices}
          />
        <% end %>
      </div>

      <Transcript.who
        :if={@who}
        name={@who.name || "Someone"}
        pronouns={@who.pronouns}
        cover={@who.cover}
        colour={Voice.of_sheet(@who)}
        on_close="close_who"
      />

      <Kit.strip sentence={@strip.sentence} tone={@strip.tone}>
        <:slot_item
          :for={s <- @strip.slots}
          label={s.label}
          state={s.state}
          colour={s.colour}
          you={s.you}
          patch={slot_view(s, @cast, @scene_id, @viewer)}
        />
      </Kit.strip>

      <%!-- The bottom bar. A player writes; the GM directs. --%>
      <div
        class="say-bar shrink-0 px-4 py-3"
        style="background:var(--b2);border-top:1px solid var(--rule)"
      >
        <Kit.waiting_line :if={beat_busy?(@progress)} label={progress_label(@progress, @cast)} />

        <.draft_card
          :for={d <- @drafts}
          draft={d}
          cast={@cast}
          voices={@voices}
          register={@register}
          editing={@editing_draft == d.row.id}
        />

        <%!-- The walk has stopped on this character and is holding the beat open for
              them (§A1). Said out loud, because otherwise the only difference between
              "your slot is waiting" and "you are speaking out of turn" is which one
              produces a double turn later. --%>
        <div
          :if={your_slot?(assigns)}
          class="flex items-center gap-2 mb-2 px-3 py-2 rounded-lg"
          style="background:color-mix(in srgb,var(--lamp) 12%,transparent)"
        >
          <Kit.dot colour="var(--lamp)" />
          <span class="text-[12.5px] flex-1">The scene is waiting on your turn.</span>
          <Kit.btn size={:sm} kind={:ghost} type="button" phx-click="pass_turn">Pass</Kit.btn>
        </div>

        <form :if={@speaker} id="say-form" phx-submit="say">
          <div class="flex items-center gap-1.5 mb-2 flex-wrap">
            <span class="lbl dim">Say it as</span>
            <span class="pill" style={"border-color:#{Voice.of(@voices, @speaker)};color:#{Voice.of(@voices, @speaker)}"}>
              <%= name_of(@cast, @speaker) %>
            </span>
            <span class="lbl dim">· whisper with (whisper to NAME: …)</span>
          </div>
          <label for="say-input" class="sr-only">What does <%= name_of(@cast, @speaker) %> do?</label>
          <textarea
            id="say-input"
            name="text"
            rows="1"
            class="field say-input px-3.5 py-3 text-[15px] w-full"
            phx-hook="ComposerInput"
            phx-update="ignore"
            autocomplete="off"
            placeholder={"What does #{name_of(@cast, @speaker)} do?"}
          ></textarea>
          <div class="flex items-center justify-between mt-2.5 gap-2">
            <div class="flex items-center gap-1.5">
              <Kit.btn
                kind={:ghost}
                type="button"
                data-composer-expand="true"
                disabled={@composing or beat_busy?(@progress)}
                title="Draft or expand this turn for you — you can edit it before sending"
              >
                <%= if @composing, do: "✦ …", else: "✦ Expand" %>
              </Kit.btn>
              <%!-- The field grows to about five lines and then scrolls; past that
                    the transcript it answers has gone off the top. For a turn that is
                    genuinely long, this hands the whole screen over instead. Plain JS
                    like the rest of the composer — a class on <body>, so a re-render
                    can't drop it.

                    One button, labelled for the state it is in. Full screen covers the
                    scene you are answering, and on a phone there is no Escape key to
                    get back to it, so the way out has to be visible and say so. --%>
              <Kit.btn
                kind={:ghost}
                type="button"
                id="composer-fullscreen"
                aria-pressed="false"
                title="Write with the whole screen"
              >
                <span class="say-enter">⤢ Full screen</span>
                <span class="say-exit">⤡ Close full screen</span>
              </Kit.btn>
            </div>
            <Kit.btn kind={:primary} type="submit" disabled={beat_busy?(@progress)}>
              Take the turn
            </Kit.btn>
          </div>
        </form>

        <%!-- The GM has no composer: to write a character you become them, which the
              strip's sentence says out loud. Narrate is the one thing only the GM can
              write, because it isn't anybody's turn. --%>
        <div :if={is_nil(@speaker)}>
          <form
            :if={@narrating}
            id="narrate-form"
            phx-submit="narrate"
            phx-change="sync_narrate"
            class="mb-2"
          >
            <label for="narrate-input" class="lbl dim">What happens</label>

            <%!-- Drawn where the words will land, like every other wait. The textarea
                  is replaced rather than sat beside: an empty box is what nothing
                  happening looks like, and there is nothing here to lose. --%>
            <Kit.skel_lines
              :if={@drafting_narration}
              class="mt-1.5"
              lines={["100%", "72%"]}
              label="Drafting what happens"
            />
            <textarea
              :if={not @drafting_narration}
              id="narrate-input"
              name="text"
              rows="2"
              class="field say-input px-3.5 py-3 text-[15px] w-full mt-1.5"
              autocomplete="off"
              phx-debounce="200"
              placeholder="The tide bell rings twice…"
            ><%= @narrating_draft %></textarea>

            <div class="flex items-center justify-between gap-2 mt-2">
              <%!-- The one move that is entirely the author's was the only one on this
                    bar with no ✦. It takes what is typed and sharpens it, or writes one
                    from nothing — the same two behaviours ✦ has everywhere else. --%>
              <Kit.btn
                kind={:ghost}
                type="button"
                phx-click="expand_narrate"
                disabled={@drafting_narration}
                title="Draft what happens — you can edit it before narrating"
              >
                <%= if @drafting_narration, do: "✦ …", else: "✦ Expand" %>
              </Kit.btn>
              <div class="flex gap-1.5">
                <Kit.btn kind={:ghost} type="button" phx-click="cancel_narrate">Cancel</Kit.btn>
                <Kit.btn kind={:primary} type="submit" disabled={@drafting_narration}>
                  Narrate it
                </Kit.btn>
              </div>
            </div>
          </form>

          <div class="flex items-center justify-between gap-2">
            <div class="flex gap-2">
              <Kit.btn :if={not @narrating} kind={:ghost} type="button" phx-click="narrate_open">
                Narrate
              </Kit.btn>
              <Kit.btn kind={:ghost} type="button" phx-click="toggle_cast">
                Cast <span class="dim"><%= length(@roster) %></span>
              </Kit.btn>
              <Kit.btn :if={@introductions != []} kind={:ghost} type="button" phx-click="toggle_intros">
                Introductions <span class="dim"><%= length(@introductions) %></span>
              </Kit.btn>
            </div>
            <Kit.btn kind={:primary} type="button" phx-click="continue" disabled={beat_busy?(@progress)}>
              Continue
            </Kit.btn>
          </div>
        </div>
      </div>

      <%!-- Author panels: the cast's control modes, and the Director's pending
            introductions. Both are GM tooling — a player never sees either. --%>
      <div :if={@panel == :cast and @viewer == :omniscient} class="row px-4 py-3">
        <div class="lbl dim mb-2">Who drives each character</div>
        <div :for={c <- @roster} class="flex items-center justify-between gap-2 py-1.5">
          <span class="text-[13px] font-semibold" style={"color:#{Voice.of(@voices, c)}"}>
            <%= name_of(@cast, c) %>
          </span>
          <form id={"control-#{c}"} phx-change="set_control">
            <input type="hidden" name="character" value={c} />
            <label for={"control-select-#{c}"} class="sr-only">Control mode</label>
            <select id={"control-select-#{c}"} name="control" class="field px-2 py-1 text-[12px]">
              <option value="autonomous" selected={control_of(@control_modes, c) == "autonomous"}>
                Automated
              </option>
              <option value="assisted" selected={control_of(@control_modes, c) == "assisted"}>
                Draft &amp; approve
              </option>
              <option value="user_controlled" selected={control_of(@control_modes, c) == "user_controlled"}>
                I write their turns
              </option>
            </select>
          </form>
        </div>
        <%!-- Bring somebody else in. A scene opens with the cast the author picked for
              it, so the rest of the campaign has to be reachable from here or the only
              way to add a latecomer is to start the scene again. `admit/3` is the same
              path an accepted introduction takes — enter, seed their context, and note
              them in the Director's brief — so a character walked in by hand and one
              the Director asked for arrive identically. --%>
        <div :if={@joinable != []} class="mt-3">
          <form id="scene-add-cast" phx-submit="add_to_scene" class="flex gap-1.5">
            <label for="scene-add-select" class="sr-only">Bring someone into the scene</label>
            <select id="scene-add-select" name="id" class="field px-2 py-1 text-[12px] flex-1 min-w-0">
              <option :for={c <- @joinable} value={c.id}><%= char_name(c) %></option>
            </select>
            <Kit.btn kind={:ghost} size={:sm} type="submit">Bring in</Kit.btn>
          </form>
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            They enter at this beat, knowing only what the scene has shown since.
          </p>
        </div>

        <%!-- The walk-ons this story invented and never wrote. `SceneControl` refuses
              a non-`:full` character, so they cannot be options in the picker above —
              the honest offer is *write them, then bring them in*, which is one press
              and the same `play.intro` an accepted Director introduction takes. Without
              this, a side character a scene actually calls for was unreachable from
              play: the only route was leaving the scene for the campaign's cast tab. --%>
        <div :if={@writable != []} class="mt-3">
          <div class="lbl dim mb-1.5">Not written yet</div>
          <div class="flex flex-col gap-1.5">
            <div :for={c <- @writable} class="flex items-center justify-between gap-2">
              <span class="text-[12.5px] min-w-0 truncate"><%= char_name(c) %></span>
              <Kit.btn
                size={:sm}
                type="button"
                phx-click="write_in"
                phx-value-id={c.id}
                disabled={MapSet.member?(@writing_in, c.id)}
                class="shrink-0"
              >
                <%= if MapSet.member?(@writing_in, c.id), do: "✦ …", else: "✦ Write them in" %>
              </Kit.btn>
            </div>
          </div>
          <p class="text-[11px] leading-relaxed dim mt-1.5">
            They're written from their role and this world, then walk in at this beat.
          </p>
        </div>

        <p
          :if={@joinable == [] and @writable == [] and @roster != []}
          class="text-[11px] leading-relaxed dim mt-3"
        >
          Everyone this campaign has written is already here.
        </p>

        <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="find_mentions" class="mt-2">
          Find mentioned characters
        </Kit.btn>
      </div>

      <div :if={@panel == :intros and @introductions != []} class="row px-4 py-3">
        <div class="lbl dim mb-2">The Director suggests</div>
        <div :for={i <- @introductions} class="flex items-center gap-2.5 py-1.5">
          <div class="min-w-0 flex-1">
            <div class="text-[13px] font-semibold"><%= i.name %></div>
            <div :if={i.reason not in [nil, ""]} class="text-[11px] dim"><%= i.reason %></div>
          </div>
          <Kit.btn
            :if={i.resolution.status == :ready}
            kind={:primary}
            size={:sm}
            phx-click="intro_admit"
            phx-value-name={i.name}
          >
            Admit
          </Kit.btn>
          <Kit.btn
            :if={i.resolution.status != :ready}
            kind={:primary}
            size={:sm}
            phx-click="intro_generate"
            phx-value-name={i.name}
          >
            ✦ Write &amp; admit
          </Kit.btn>
          <Kit.btn kind={:pen} size={:sm} phx-click="intro_edit" phx-value-name={i.name}>Edit</Kit.btn>
          <Kit.btn kind={:pen} size={:sm} phx-click="intro_dismiss" phx-value-name={i.name}>
            Not now
          </Kit.btn>
        </div>
      </div>
    </Kit.frame>
    """
  end

  # ── Transcript blocks ─────────────────────────────────────────────────────────

  attr(:id, :string, required: true)
  attr(:block, :map, required: true)
  attr(:register, :atom, required: true)
  attr(:cast, :any, required: true)
  attr(:voices, :map, required: true)
  attr(:beat_rule, :any, default: nil)
  attr(:editable, :boolean, default: false)
  attr(:editing, :string, default: nil)
  attr(:control, :string, default: nil)

  defp turn_block(assigns) do
    assigns =
      assigns
      |> assign(:colour, Voice.of(assigns.voices, assigns.block.character))
      |> assign(:name, name_of(assigns.cast, assigns.block.character))

    ~H"""
    <div id={@id} class="turn-block">
      <Kit.beat_rule :if={@beat_rule} beat={@beat_rule} />

      <%!-- An event with no packet — a world beat, an entrance — is nobody's turn,
            so it carries no attribution and no editorial controls. --%>
      <div :if={@block.type == :event} class="py-1">
        <div :for={m <- @block.msgs}><%= Transcript.render_move(m, @cast, @register, @voices) %></div>
      </div>

      <div
        :if={@block.type == :turn}
        class={["mb-4", @register == :stage && "pl-3"]}
        style={@register == :stage && "box-shadow:inset 2px 0 0 #{@colour}"}
      >
        <div class="flex items-center gap-2 mb-1.5 flex-wrap">
          <%!-- The name is the way in to who this is — the same control the reading
                screen has, so a character somebody meets mid-scene can be asked about
                without leaving the scene. --%>
          <button
            type="button"
            class={["ttl font-semibold text-left", @register == :stage && "text-[14px]", @register == :page && "text-[13px] tracking-[.06em]"]}
            style={"color:#{@colour}"}
            phx-click="who"
            phx-value-id={@block.character}
            aria-label={"About #{@name}"}
          >
            <%= if @register == :page, do: String.upcase(@name), else: @name %>
          </button>
          <Kit.pill :if={@register == :stage and @control} class="dim">
            <%= control_label(@control) %>
          </Kit.pill>
        </div>

        <div :for={m <- Transcript.ordered_moves(@block.msgs)}>
          <%= Transcript.render_move(m, @cast, @register, @voices) %>
        </div>

        <div :if={@editable and @editing != @block.packet_id} class="turn-controls flex flex-wrap gap-0.5 mt-2 -ml-1">
          <Kit.btn kind={:pen} phx-click="reroll_turn" phx-value-beat={@block.beat} phx-value-character={@block.character}>
            Reroll
          </Kit.btn>
          <Kit.btn kind={:pen} phx-click="edit_turn" phx-value-packet={@block.packet_id}>Edit</Kit.btn>
          <Kit.btn
            kind={:pen}
            phx-click="delete_turn"
            phx-value-beat={@block.beat}
            phx-value-character={@block.character}
            phx-value-packet={@block.packet_id}
            data-confirm="Remove this turn?"
          >
            Delete
          </Kit.btn>
        </div>

        <form
          :if={@editable and @editing == @block.packet_id}
          id={"edit-#{@block.packet_id}"}
          phx-submit="save_edit"
          class="turn-edit mt-2"
        >
          <input type="hidden" name="beat" value={@block.beat} />
          <input type="hidden" name="character" value={@block.character} />
          <input type="hidden" name="packet" value={@block.packet_id} />
          <label for={"edit-text-#{@block.packet_id}"} class="sr-only">Edit this turn</label>
          <textarea
            id={"edit-text-#{@block.packet_id}"}
            name="text"
            rows="3"
            class="field say-input px-3 py-2 text-[14px] w-full"
          ><%= turn_text(@block, @cast) %></textarea>
          <%!-- The question `Edit.edit/6` has always asked and nothing ever put to
                anybody. Serial generation means a changed line may have changed what
                *later* turns conditioned on, and only the author knows whether it did:
                a typo didn't, a reversal did. Answering "it changed what happened"
                forks at this beat, so the original timeline survives intact and the
                stale tail is discarded on the branch rather than left standing under a
                turn that no longer says what it said. --%>
          <div class="mt-2">
            <label class="flex items-start gap-2 cursor-pointer">
              <input type="checkbox" name="invalidates" value="true" class="sr-only peer" />
              <Kit.chk state={:off} class="mt-0.5 peer-checked:hidden" />
              <Kit.chk state={:on} class="mt-0.5 hidden peer-checked:flex" />
              <span class="text-[12px] leading-relaxed">
                This changes what happened
                <span class="dim block">
                  Branches the scene here, keeping the original — anything written after
                  this turn was written on top of it.
                </span>
              </span>
            </label>
          </div>

          <div class="flex gap-1.5 mt-1.5">
            <Kit.btn kind={:primary} size={:sm} type="submit">Save</Kit.btn>
            <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="cancel_edit">Cancel</Kit.btn>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # A turn that was generated and is waiting to be taken (§A2). Rendered through the
  # *same* `render_move/4` the transcript uses, so what is approved reads exactly as
  # it will read once committed — a second renderer here would drift, and the whole
  # point of approving is seeing the thing itself.
  attr(:draft, :map, required: true)
  attr(:cast, :any, required: true)
  attr(:voices, :map, required: true)
  attr(:register, :atom, required: true)
  attr(:editing, :boolean, default: false)

  defp draft_card(assigns) do
    assigns =
      assigns
      |> assign(:colour, Voice.of(assigns.voices, assigns.draft.row.character_id))
      |> assign(:name, name_of(assigns.cast, assigns.draft.row.character_id))

    ~H"""
    <Kit.sheet class="mb-3" style={"border-color:#{@colour}"}>
      <Kit.row class="px-3.5 py-2 flex items-center gap-2 flex-wrap" style="background:var(--b2)">
        <span class="ttl text-[14px] font-semibold" style={"color:#{@colour}"}><%= @name %></span>
        <Kit.pill class="dim">Waiting on you</Kit.pill>
        <span class="flex-1"></span>
        <span class="lbl dim">beat <%= @draft.row.beat %></span>
      </Kit.row>

      <div :if={not @editing} class="px-3.5 py-2.5">
        <div :for={m <- draft_moves(@draft, @draft.row.character_id)}>
          <%= Transcript.render_move(m, @cast, @register, @voices) %>
        </div>
      </div>

      <%!-- A turn that is nearly right is the ordinary case, and the whole argument for
            approving one instead of letting it commit. Same editor format as the
            transcript's, so correcting a draft and correcting a committed turn are the
            same skill. --%>
      <form
        :if={@editing}
        id={"draft-edit-#{@draft.row.id}"}
        phx-submit="save_draft_edit"
        class="px-3.5 py-2.5"
      >
        <%!-- `draft_id`, not `id`: LiveView reserves that name for the form's own DOM
              id and warns that the value would be remapped underneath us. --%>
        <input type="hidden" name="draft_id" value={@draft.row.id} />
        <label for={"draft-text-#{@draft.row.id}"} class="sr-only">Edit this turn</label>
        <textarea
          id={"draft-text-#{@draft.row.id}"}
          name="text"
          rows="4"
          class="field say-input px-3 py-2 text-[14px] w-full"
        ><%= draft_text(@draft, @cast) %></textarea>
        <div class="flex gap-1.5 mt-1.5">
          <Kit.btn kind={:primary} size={:sm} type="submit">Save</Kit.btn>
          <Kit.btn kind={:ghost} size={:sm} type="button" phx-click="cancel_draft_edit">
            Cancel
          </Kit.btn>
        </div>
      </form>

      <Kit.row :if={not @editing} class="px-3.5 py-2.5 flex items-center gap-1.5 flex-wrap">
        <Kit.btn kind={:primary} size={:sm} type="button"
                 phx-click="accept_draft" phx-value-id={@draft.row.id}>
          Take it
        </Kit.btn>
        <Kit.btn kind={:ghost} size={:sm} type="button"
                 phx-click="edit_draft" phx-value-id={@draft.row.id}>
          Edit first
        </Kit.btn>
        <%!-- Discarding is a **pass**, not a deletion — the slot gives up its turn and
              the beat walks on, which is what the backend does with it. Saying
              "discard" alone would read as "try again". --%>
        <Kit.btn kind={:pen} size={:sm} type="button"
                 phx-click="discard_draft" phx-value-id={@draft.row.id}>
          Discard — they pass
        </Kit.btn>
      </Kit.row>
    </Kit.sheet>
    """
  end

  # A draft holds `TurnPacket.Move` structs; the transcript renders committed *events*.
  # Mapping one onto the other is what lets both go through a single renderer.
  defp draft_moves(%{packet: %{moves: moves}}, character_id) do
    moves
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(fn m ->
      case m.type do
        :speech ->
          %{
            kind: "SpeechUttered",
            payload: %{
              content: m.content,
              audibility: m.audibility,
              addressed_to: m.addressed_to
            }
          }

        :thought ->
          %{kind: "ThoughtOccurred", payload: %{content: m.content, character_id: character_id}}

        _ ->
          %{kind: "ActionTaken", payload: %{content: m.content}}
      end
    end)
  end

  defp draft_moves(_draft, _character_id), do: []

  defp control_label("assisted"), do: "Draft & approve"
  defp control_label("user_controlled"), do: "Yours"
  defp control_label(_), do: "Automated"

  defp empty_headline(:omniscient), do: "Nobody has moved yet."
  defp empty_headline(_), do: "Nothing has happened yet."

  # The viewpoint's hue: a character's voice, or the register's plain foreground for
  # the omniscient author (per the kit's perspective-control spec).
  defp viewer_colour(:omniscient, _voices), do: Voice.neutral()
  defp viewer_colour({:character, id}, voices), do: Voice.of(voices, id)

  # One debug-timeline entry, stacked (never a horizontal table — unreadable on mobile):
  # a wrapping meta line, then the detail below it. Entries are separated by a rule via
  # `.dbg-entry`'s bottom border.
  defp render_debug_entry(%{kind: :event} = assigns) do
    ~H"""
    <div class="dbg-meta">
      <span class="dbg-time"><%= at_label(@at_ms) %></span>
      <span class="dbg-tag ev">event</span>
      <span class="faint">#<%= @seq %> · b<%= @beat %></span>
      <strong><%= @label %></strong>
    </div>
    <pre class="dbg-detail"><%= @detail %></pre>
    """
  end

  defp render_debug_entry(%{kind: :trace} = assigns) do
    ~H"""
    <details>
      <summary>
        <span class="dbg-time"><%= at_label(@at_ms) %></span>
        <span class={"dbg-tag llm #{if @is_error, do: "err"}"}>LLM</span>
        <strong><%= @subject %></strong>
        <span class="faint"><%= @model %> · <%= @outcome %></span>
      </summary>
      <div class="dbg-kv faint">params: <%= @params %></div>
      <div class="dbg-label">request</div>
      <pre class="dbg-detail"><%= @request %></pre>
      <div class="dbg-label">response</div>
      <pre class="dbg-detail"><%= @response %></pre>
    </details>
    """
  end

  defp render_debug_entry(%{kind: :error} = assigns) do
    ~H"""
    <div class="dbg-meta">
      <span class="dbg-time"><%= at_label(@at_ms) %></span>
      <span class="dbg-tag err">error</span>
      <strong><%= @subject %></strong>
      <span :if={@beat} class="faint">b<%= @beat %></span>
    </div>
    <div class="dbg-detail err"><%= @detail %></div>
    """
  end
end
