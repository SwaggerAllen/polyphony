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
  types is a display name, resolved through `PolyphonyCore.Scene.Cast` at the edge:
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

  alias Polyphony.{App, Broadcast, Context, DebugFlags, Drafts, Failures, Library, SceneControl}
  alias Polyphony.Owner
  alias PolyphonyCore.{MembershipSet, TurnOrder}

  alias Polyphony.Context.{Store, PgvectorRetriever, Rebuild}
  alias Polyphony.Director.{Auto, BeatDriver}
  alias Polyphony.Branching
  alias Polyphony.Campaigns
  alias Polyphony.Characters
  alias Polyphony.Edit
  alias Polyphony.Generations
  alias Polyphony.Permissions
  alias PolyphonyCore.Scene.Cast
  alias PolyphonyWeb.Play.Strip
  alias PolyphonyWeb.Transcript
  alias PolyphonyWeb.Screens.Play
  alias PolyphonyWeb.Voice
  alias Polyphony.Authoring.Effective
  alias Polyphony.DebugTap
  alias Polyphony.Director.{BeatOps, SceneBrief}

  alias PolyphonyCore.Commands.{
    CommitPacket,
    DeclareTurnOrder,
    EnterCharacter,
    ExitCharacter,
    DismissIntroduction,
    RecordWorldEvent,
    SetControlMode,
    SupersedePacket
  }

  alias Polyphony.Authoring.{ArcAccept, CharacterSheet, Stub, WorldBible}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM
  alias Polyphony.Repo

  alias PolyphonyCore.Events.{
    IntroductionProposed,
    IntroductionDismissed,
    CharacterEntered,
    SceneOpened,
    SpeechUttered,
    ActionTaken,
    WorldEventOccurred
  }

  alias PolyphonyCore.TurnPacket
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
    # Keyed by the beat's own number, which is what makes a re-insert land on the node it
    # replaces rather than appending a second copy of the beat.
    socket = stream_configure(socket, :beats, dom_id: &"beat-#{&1.beat}")

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
      # An auto run outlives the tab that started it, so its state is read on mount and
      # subscribed for the rest — the same contract Quick Build's progress uses.
      Auto.subscribe(scene_id)
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
       # Not `Play.idle()`: the loop may well be mid-beat right now, and until this read
       # existed a reload (or simply opening the scene from another screen) came back
       # showing nothing — no placeholder, no waiting line, and Continue live enough to
       # race a second beat into a scene that was already advancing.
       progress: Broadcast.progress(scene_id),
       auto: Auto.get(scene_id),
       introductions: [],
       suggestion: nil,
       intros_view: :panel,
       arc_gate: nil,
       intro_control: "autonomous",
       admitted: [],
       sending_away: nil,
       new_name: "",
       new_premise: "",
       picker_query: "",
       picker_tier: "all",
       picker_rows: [],
       picker_chosen: nil,
       control_modes: %{},
       failures: [],
       drafts: [],
       editing_draft: nil,
       editing: nil,
       composing: false,
       debug_events: DebugFlags.get(:events),
       debug_trace: DebugFlags.get(:trace),
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
       strip: %{slots: [], sentence: nil, tone: nil},
       transcript_empty: true,
       branch: nil,
       branching: nil
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
    cast = Rebuild.cast_for(scene_id)
    # Voice colours come from the hue stored on each sheet, so they're stable across
    # the transcript, the strip and the perspective control — and stable across a
    # cast change, which is what deriving them from order could never be.
    voices = Map.new(cast.id_to_hue, fn {id, hue} -> {id, Voice.colour(hue)} end)

    traces = if socket.assigns.debug_trace, do: DebugTap.recent(scene_id), else: []
    failures = open_failures(socket)
    feed = debug_feed(socket, traces, failures)
    intros = intro_queue(socket, plain, cast)

    assign(socket,
      messages: messages,
      traces: traces,
      roster: roster,
      joinable: joinable(socket, roster),
      writable: writable(socket, roster),
      # In the room without a sheet — derived from the roster, never tracked, so a
      # reconnect comes back to the same panel.
      admitted: admitted(socket, roster),
      cast: cast,
      voices: voices,
      strip:
        Strip.build(
          beat_events: BeatOps.beat_events(scene_id, max(next_beat - 1, 1)),
          order: TurnOrder.for_beat(plain, max(next_beat - 1, 1)),
          members: roster,
          viewer: socket.assigns.viewer,
          generating: Play.generating_now(socket.assigns.progress),
          names: cast.id_to_name,
          voices: voices
        ),
      next_beat: next_beat,
      premise: scene_premise(plain),
      campaign_name: campaign_name(socket),
      branch: branch_pill(socket),
      scene_title: scene_title(plain),
      control_modes: Map.new(roster, fn c -> {c, TurnOrder.control_mode(plain, c)} end),
      # The Director's pending introductions — author-facing tooling, so only the
      # omniscient view shows the queue (and each carries how it resolves).
      introductions: intros,
      # The panel shows **one**, because the GM is being asked to ratify a judgement about
      # the scene rather than pick from a queue. The rest stay in `introductions`, which is
      # still what dismiss and admit key off — the next one surfaces when this one is
      # answered.
      suggestion: suggestion_of(intros),
      failures: failures,
      drafts: open_drafts(scene_id),
      debug_feed: feed,
      debug_feed_text: feed_text(feed)
    )
    # Last, and reset: everything it reads — the messages, the failures, the beat the
    # scene has reached — is assigned above, and a reload is a re-projection rather than a
    # delta, so the client clears and takes the whole tree.
    |> stream_beats(reset: true)
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

  # The suggestion the panel draws, or nil when the Director isn't asking. A proposal is
  # by **name** — it can name somebody who doesn't exist yet — so the swatch is the
  # resolved character's voice where there is one and the neutral where there isn't.
  # Nobody has a palette place until they are in the campaign.
  defp suggestion_of([]), do: nil

  defp suggestion_of([intro | _rest]) do
    %{
      name: intro.name,
      reason: Map.get(intro, :reason),
      colour: colour_of(Map.get(intro, :resolution)),
      # One button says **Admit** whichever this is. The panel used to offer *Admit* or
      # *✦ Write & admit* depending on whether the name resolved to somebody already
      # written — which made the GM answer a question about the database in the middle
      # of a question about the scene. Every path ends with a full character, so the
      # difference is only how long the sheet takes to arrive.
      ready?: Map.get(intro, :resolution, %{}) |> Map.get(:status) == :ready
    }
  end

  defp colour_of(%{entry: entry}) when not is_nil(entry),
    do: entry |> Library.payload() |> Voice.of_sheet()

  defp colour_of(_resolution), do: Voice.neutral()

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
  defp ensure_character(socket, name), do: stub_for(socket, name, "")

  # The same, carrying the *who are they* line the panel's form collected. It is the
  # stub's `role`, which is the seed `Autofill` folds into the generation context — so a
  # sentence typed into play survives into the sheet rather than being decoration on a
  # form. A name that already belongs to somebody wins over the premise: the author is
  # naming a person, not describing a new one.
  defp stub_for(socket, name, premise) do
    case Map.get(owner_characters(socket.assigns.current_user), String.downcase(name)) do
      nil ->
        entry =
          Library.put(%{
            owner: Owner.of(socket.assigns.current_user),
            kind: "character",
            payload:
              Stub.new(name, presence(premise, ""), world_bible_id: campaign_world_id(socket))
          })

        # Somebody introduced mid-scene belongs to the story they walked into.
        Campaigns.cast(campaign_of(socket.assigns.scene_id), entry.id)
        entry

      entry ->
        entry
    end
  end

  defp presence(value, fallback) do
    case String.trim(to_string(value || "")) do
      "" -> fallback
      text -> text
    end
  end

  # Enter a finalized character into the scene at the current beat boundary and seed
  # their frozen context so the Director loop can cast them next. The character enters
  # by **library id** (§5.2) — the same mint as scene open — with the name kept only
  # for what the author reads.
  # The gate, met on the way in (STR-62). `arc_review.md` says the review is the same
  # component in all three places you cast somebody, and this is two of them: adding
  # someone mid-scene, and admitting a Director proposal. A character enters as their
  # sheet reads, so entering one with unreviewed arc puts somebody two scenes out of
  # date on stage — the same staleness the scene-setup gate exists to prevent.
  #
  # Only *their* pending arc counts. Pending world arc gates opening a scene, because a
  # world fact is true for everybody; this scene is already open, and the world's
  # backlog says nothing about whether this person's sheet is current.
  defp admit(socket, entry, %CharacterSheet{} = sheet) do
    case ArcRM.list_proposed(Repo, to_string(entry.id)) do
      [] -> do_admit(socket, entry, sheet)
      pending -> open_arc_gate(socket, entry, sheet, pending)
    end
  end

  defp admit(socket, _entry, _other),
    do: put_flash(socket, :error, "That character has no usable sheet yet.")

  defp arc_gate_act(socket, fun, id) do
    safe(socket, fn ->
      fun.(String.to_integer(id))
      {:noreply, socket |> update_arc_gate(&%{&1 | editing: nil}) |> refresh_arc_gate()}
    end)
  end

  defp update_arc_gate(socket, fun) do
    case socket.assigns.arc_gate do
      nil -> socket
      gate -> assign(socket, arc_gate: fun.(gate))
    end
  end

  defp refresh_arc_gate(socket) do
    case socket.assigns.arc_gate do
      nil ->
        socket

      gate ->
        assign(socket, arc_gate: %{gate | proposals: ArcRM.list_proposed(Repo, gate.id)})
    end
  end

  # The entrance the gate interrupted, now that they are current.
  defp continue_admission(socket, gate) do
    entry = Library.get(gate.id)
    sheet = entry && Library.payload(entry)

    if match?(%CharacterSheet{}, sheet) do
      socket |> assign(arc_gate: nil) |> close_intros() |> do_admit(entry, sheet)
    else
      socket |> assign(arc_gate: nil, intros_view: :panel) |> put_flash(:error, "They're gone.")
    end
  end

  defp open_arc_gate(socket, entry, sheet, pending) do
    socket
    |> assign(
      intros_view: :arc_gate,
      arc_gate: %{
        id: to_string(entry.id),
        name: sheet.name,
        colour: Voice.of_sheet(sheet),
        proposals: pending,
        editing: nil
      }
    )
    |> assign(panel: :intros)
  end

  defp do_admit(socket, entry, %CharacterSheet{name: name} = sheet) do
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

    socket
    |> assign(arc_gate: nil, intros_view: :panel)
    |> reload()
    |> put_flash(:info, "#{name} joins the scene.")
  end

  # ── Admit first, write after (§07, `admitted_writing`) ────────────────────────
  #
  # The panel's *write someone new* door brings them on **before** the sheet exists,
  # which is the opposite order from `write_in` and deliberately so: the entrance is
  # what the room reacts to, and making the GM watch a spinner before anybody arrives
  # turns a dramatic beat into a progress bar. They enter, they cannot act (the beat
  # loop only casts `:full` characters), and the write lands underneath them.
  #
  # `writing_in` doubles as the in-flight set here, so a reconnect mid-write comes back
  # in the same state — it is rebuilt from the running generations on mount.
  defp write_in_new(socket, name, premise) do
    entry = stub_for(socket, name, premise)
    sheet = Library.payload(entry)

    if match?(%CharacterSheet{status: :full}, sheet) do
      # The name resolved to somebody already written. Nothing to wait for.
      socket |> set_control(to_string(entry.id)) |> close_intros() |> admit(entry, sheet)
    else
      socket
      |> set_control(to_string(entry.id))
      # Marked as in-flight **before** the entrance, because entering reloads and the
      # reload is what derives `admitted`. The other order renders them for one frame as
      # somebody whose write already failed.
      |> assign(writing_in: MapSet.put(socket.assigns.writing_in, entry.id))
      |> enter_pending(entry, sheet)
      # Back to the panel rather than closed: they are in the room and their sheet is
      # still being written, and the panel is where that is said and where the ways out
      # of it live. Closing it would be the app losing track of somebody it has just put
      # on stage.
      |> back_to_panel()
      |> request_generation(
        "write_in:#{entry.id}",
        "play.intro",
        Map.merge(%{entry_id: entry.id}, billing(socket))
      )
    end
  end

  # Enter somebody whose sheet hasn't been written yet. Same `EnterCharacter` as any
  # other arrival — the log doesn't have a provisional kind of member, and inventing one
  # would put "is this person real" into every projection that reads membership. What is
  # deliberately *not* done here is `SceneBrief.note_character/2`: there is nothing to
  # tell the Director about yet, and a brief describing an empty sheet is worse than one
  # that mentions nobody. Both it and the frozen context are done again by
  # `settle_admitted/3` once the sheet lands.
  defp enter_pending(socket, entry, sheet) do
    :ok =
      App.dispatch(%EnterCharacter{
        scene_id: socket.assigns.scene_id,
        character_id: to_string(entry.id),
        beat: max(socket.assigns.next_beat - 1, 1)
      })

    name = (match?(%CharacterSheet{}, sheet) && sheet.name) || "They"
    socket |> reload() |> put_flash(:info, "#{name} joins the scene.")
  end

  # The write landed for somebody already in the room: give them the context and the
  # brief entry they entered without. Not `admit/3` — they are already a member, and a
  # second `EnterCharacter` is `{:error, :already_present}`.
  defp settle_admitted(socket, entry, %CharacterSheet{} = sheet) do
    seed_context(
      socket.assigns.scene_id,
      to_string(entry.id),
      sheet,
      socket.assigns.premise,
      campaign_world_bible(socket)
    )

    SceneBrief.note_character(socket.assigns.scene_id, sheet)
    socket |> reload() |> put_flash(:info, "#{sheet.name} is written.")
  end

  # Who is in the room without a sheet — derived from membership rather than tracked,
  # so it survives a reconnect and can't disagree with the roster. `:writing` while a
  # generation is in flight for them, `:failed` when there is none: a character sitting
  # in a scene with a stub and nothing running is exactly the failed case, however the
  # generation died. Author-facing, so omniscient only.
  defp admitted(socket, roster) do
    if socket.assigns.viewer == :omniscient do
      for id <- roster,
          entry = Library.get(id),
          entry != nil,
          sheet = Library.payload(entry),
          match?(%CharacterSheet{}, sheet),
          sheet.status != :full,
          do: %{
            id: entry.id,
            name: sheet.name,
            colour: Voice.of_sheet(sheet),
            status:
              if(MapSet.member?(socket.assigns.writing_in, entry.id), do: :writing, else: :failed)
          }
    else
      []
    end
  end

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

  # Who a generation started from this screen is billed to (§B5).
  #
  # `campaign_id` is the half that was missing. Every ✦ here built its own meter opts
  # by hand with only a `user_id`, so a turn drafted in a scene, a narration, a walk-on
  # written in and a mention sweep all landed in the *unattributed* bucket — which the
  # settings breakdown labels "authoring", i.e. the one place a scene's spend can't be
  # seen. The Director loop resolved this properly all along (`Attribution.for_scene`);
  # the screen didn't. Supplying it also puts these calls under the campaign's own
  # lifetime cap, which is where they always belonged.
  defp meter(socket, kind) do
    uid = socket.assigns.current_user && socket.assigns.current_user.id

    [usage_kind: kind] ++
      if(uid, do: [user_id: uid], else: []) ++
      case campaign_of(socket.assigns.scene_id) do
        nil -> []
        cid -> [campaign_id: cid]
      end
  end

  defp narration_meter(socket), do: meter(socket, "authoring")

  # The same two fields as a map, for the ops whose request the worker meters rather
  # than the screen.
  defp billing(socket) do
    socket |> meter(nil) |> Keyword.take([:user_id, :campaign_id]) |> Map.new()
  end

  # What everybody in the scene has already seen: speech that wasn't a whisper, actions,
  # demeanour, and the Director's own moves. Thoughts are structurally invisible to
  # everyone else and a whisper reached two people — feeding either to a drafting aid

  defp maybe_payload(nil), do: nil
  defp maybe_payload(entry), do: Library.payload(entry)

  # The world bible id behind this scene's campaign, for stubbing new introductions
  # into the right setting. Nil if the scene has no campaign or world.
  defp campaign_world_id(socket) do
    with %SceneOpened{campaign_id: cid} when not is_nil(cid) <-
           scene_opened(socket.assigns.scene_id),
         campaign when not is_nil(campaign) <- Library.get(cid),
         %{bible_id: bid} <- Library.payload(campaign) do
      # A branch scene grounds new people in the line's own copy of the world.
      case Branching.line_of(cid, socket.assigns.scene_id) do
        %{parent_id: parent, bible_id: line_bid}
        when not is_nil(parent) and not is_nil(line_bid) ->
          normalize_id(line_bid)

        _ ->
          normalize_id(bid)
      end
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

  # A reconnect can't see a spinner, and it can't see an answer that arrived while the
  # tab was closed. Both come back from the rows.
  #
  # Every ✦ on this screen, not just the composer's. A ✦ that comes back looking idle is
  # worse than one that comes back looking stuck: the control is live again, so the
  # obvious move is to press it — and pressing it *replaces the claim*, which throws away
  # the answer that was seconds from arriving and pays for a second one.
  defp restore_generations(socket) do
    scene_id = socket.assigns.scene_id
    Generations.subscribe(scene_id)

    for {key, result} <- Generations.take(scene_id),
        do: send(self(), {:generation, key, result})

    running = Generations.running(scene_id)
    narrating? = "narrate" in running

    assign(socket,
      composing: "compose" in running,
      drafting_narration: narrating?,
      # The panel has to be open for its own spinner to be visible at all — a narration
      # being written behind a closed drawer is indistinguishable from nothing happening.
      narrating: socket.assigns.narrating or narrating?,
      writing_in: MapSet.new(for("write_in:" <> id <- running, do: normalize_id(id)))
    )
  end

  # The campaign's cast who aren't in this scene: castable (`:full` — `SceneControl`
  # refuses anything else) and not already on the roster. Scoped to the campaign rather
  # than the whole library, because §2.7 means a character belongs to one story and the
  # picker for *this* scene should not offer somebody else's people.
  # ── The picker's rows ──────────────────────────────────────────────────────────

  # **This campaign's roster, and nothing else** — see `play.md`'s standing decision. Not
  # the author's library, which is the mistake this is the one surface tempted to make.
  # Characters already in the scene are included rather than filtered: they render dimmed
  # and inert, which costs a row and stops the GM hunting for somebody standing in front
  # of them.
  defp load_picker(socket) do
    present = MapSet.new(socket.assigns.roster, &to_string/1)
    query = socket.assigns.picker_query |> to_string() |> String.trim() |> String.downcase()

    rows =
      for id <- campaign_character_ids(socket),
          entry = Library.get(id),
          entry != nil,
          sheet = Library.payload(entry),
          match?(%CharacterSheet{}, sheet),
          matches_tier?(sheet, socket.assigns.picker_tier),
          matches_query?(sheet, query),
          do: %{
            id: entry.id,
            name: char_name(entry),
            blurb: Map.get(sheet, :premise),
            tier_label: CharacterSheet.tier_label(Characters.tier_of(entry)),
            colour: Voice.of_sheet(sheet),
            in_scene?: MapSet.member?(present, to_string(entry.id))
          }

    assign(socket, picker_rows: rows)
  end

  defp matches_tier?(_sheet, "all"), do: true
  defp matches_tier?(sheet, tier), do: to_string(Map.get(sheet, :tier) || :main) == tier

  defp matches_query?(_sheet, ""), do: true

  defp matches_query?(sheet, query),
    do: sheet |> Map.get(:name) |> to_string() |> String.downcase() |> String.contains?(query)

  # The *they'll be* answer, applied at the moment they arrive rather than left for the
  # composer's picker afterwards — which is the whole reason the control sits on the
  # admission and not next to it.
  defp set_control(socket, character_id) do
    :ok =
      App.dispatch(%SetControlMode{
        scene_id: socket.assigns.scene_id,
        character_id: character_id,
        control: socket.assigns.intro_control
      })

    socket
  end

  defp close_intros(socket), do: socket |> back_to_panel() |> assign(panel: nil)

  # The panel's own face again, with the doors' working state cleared. Distinct from
  # closing it: `write_in_new` comes back here so the character it just walked on stage
  # is still being reported somewhere.
  defp back_to_panel(socket),
    do:
      assign(socket,
        intros_view: :panel,
        picker_chosen: nil,
        picker_query: "",
        new_name: "",
        new_premise: ""
      )

  defp joinable(socket, roster) do
    present = MapSet.new(roster, &to_string/1)

    for id <- campaign_character_ids(socket),
        entry = Library.get(id),
        entry != nil,
        not MapSet.member?(present, to_string(entry.id)),
        match?(%CharacterSheet{status: :full}, Library.payload(entry)),
        do: %{id: entry.id, name: char_name(entry)}
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
        do: %{id: entry.id, name: char_name(entry)}
  end

  # Both lists reach the screen as `%{id, name}` rather than as library entries, because
  # the screen renders from assigns and may not read the library — see
  # `PolyphonyWeb.Screens`. The handlers re-fetch by id against the offered list, which
  # is also a fix: acting on an entry cached in socket state meant acting on the sheet as
  # it stood when the beat opened.
  defp offered?(offers, id), do: Enum.any?(offers, &(to_string(&1.id) == to_string(id)))

  # The roster the picker reaches: this campaign's — and once the campaign has
  # branched, this **line's**. Copy-on-branch means a branch scene's people are
  # the line's copies, and offering the original cast here would cast the other
  # line's Wren into this one's story.
  defp campaign_character_ids(socket) do
    with cid when not is_nil(cid) <- campaign_of(socket.assigns.scene_id),
         entry when not is_nil(entry) <- Library.get(cid),
         %{} = payload <- Library.payload(entry) do
      case Branching.line_of(cid, socket.assigns.scene_id) do
        %{parent_id: parent, character_ids: ids} when not is_nil(parent) and ids != [] -> ids
        _ -> Map.get(payload, :character_ids) || []
      end
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

  # The branch pill: which line this scene is in, or nil when the campaign has
  # never branched — a campaign that has never branched is not a campaign with one
  # branch, and the header should say nothing about a shape it does not have.
  defp branch_pill(socket) do
    with cid when not is_nil(cid) <- campaign_of(socket.assigns.scene_id),
         true <- Branching.branched?(cid),
         line when not is_nil(line) <- Branching.line_of(cid, socket.assigns.scene_id) do
      %{name: line.name, canon?: line.canonical}
    else
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
    if Play.beat_busy?(socket.assigns.progress) do
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
      case Play.awaiting(socket.assigns.progress) do
        {character, beat} ->
          BeatDriver.pass_turn(socket.assigns.scene_id, beat, character)

          {:noreply,
           socket
           |> assign(progress: Play.idle())
           |> reload()
           |> put_flash(:info, "#{Play.name_of(socket, character)} passes.")}

        nil ->
          {:noreply, put_flash(socket, :error, "Nothing is waiting on you.")}
      end
    end)
  end

  def handle_event("compose", %{"text" => draft}, socket) do
    if Play.beat_busy?(socket.assigns.progress) do
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
       |> put_flash(:info, "Rerolling #{Play.name_of(socket, c)}…")
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

      {:noreply,
       socket |> put_flash(:info, "Removed #{Play.name_of(socket, c)}'s turn.") |> reload()}
    end)
  end

  def handle_event("edit_turn", %{"packet" => pid}, socket),
    do: {:noreply, socket |> assign(editing: pid) |> restream_packet(pid)}

  def handle_event("cancel_edit", _params, socket) do
    # The packet that *was* being edited — read before it is cleared, since that is the
    # beat whose markup has to lose the form.
    was = socket.assigns.editing
    {:noreply, socket |> assign(editing: nil) |> restream_packet(was)}
  end

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
          cid = campaign_of(scene)

          # Copy-on-branch: an edit that changes history is a branch, so it copies
          # the cast and world like any other — and the map has to exist before
          # the fork so the copied prefix speaks with the copies' ids.
          copies =
            if validity == :invalid and cid, do: Branching.prepare_line(cid, scene)

          edit_opts =
            [label: "edited at beat #{beat}"] ++
              if(copies, do: [character_map: copies.character_map], else: [])

          case Edit.edit(scene, beat, c, corrected, validity, edit_opts) do
            {:ok, %{forked: true, scene_id: branch}} ->
              # A branch made by an edit is a branch: record the line so the
              # navigator and the hub can see it, rather than leaving a stream only
              # the address bar knows about.
              if cid,
                do:
                  Branching.register_fork(cid, scene, branch, beat,
                    location: socket.assigns.scene_title,
                    copies: copies
                  )

              # The branch is where the corrected turn lives, so that is where the
              # author now is. The original is untouched and still reachable by its id.
              {:noreply,
               socket
               |> assign(editing: nil)
               |> put_flash(:info, "Branched here. The original scene is unchanged.")
               |> push_navigate(to: ~p"/play/#{branch}")}

            {:ok, _} ->
              # An in-place correction still changed what a reader may have read:
              # the line's divergence cursor moves if this sits earlier than it.
              if cid, do: Branching.notice_change(cid, scene, beat)

              {:noreply,
               socket
               |> assign(editing: nil)
               |> put_flash(:info, "Updated #{Play.name_of(socket, c)}'s turn.")
               |> reload()}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Couldn't edit that turn: #{inspect(reason)}")}
          end
      end
    end)
  end

  # ── Branching (STR-8) ─────────────────────────────────────────────────────────

  # The divider's ⑂ opens the confirm; nothing has happened yet. The confirm is
  # where the beat gets named — the divider deliberately says only "Branch".
  def handle_event("branch_open", %{"beat" => beat}, socket),
    do: {:noreply, assign(socket, branching: String.to_integer(beat))}

  # Walking away undoes it — nothing was created, so nothing needs cleaning up.
  def handle_event("branch_cancel", _params, socket),
    do: {:noreply, assign(socket, branching: nil)}

  # The bare "branch from here": the cut lands *before* the named beat, so the
  # copy keeps everything through the beat above the divider. You land in the
  # branch immediately — the reason somebody asks for one is that they want to
  # keep going differently, so landing anywhere else would be a detour.
  def handle_event("branch_confirm", %{"beat" => beat}, socket) do
    safe(socket, fn ->
      scene = socket.assigns.scene_id
      beat = String.to_integer(beat)

      case campaign_of(scene) do
        nil ->
          {:noreply,
           put_flash(socket, :error, "This scene isn't in a campaign, so it can't branch.")}

        cid ->
          case Branching.branch_from(cid, scene, beat - 1, location: socket.assigns.scene_title) do
            {:ok, %{scene_id: new_scene}} ->
              {:noreply,
               socket
               |> assign(branching: nil)
               |> put_flash(:info, "Branched here. This scene stays exactly as it is.")
               |> push_navigate(to: ~p"/play/#{new_scene}")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Couldn't branch: #{inspect(reason)}")}
          end
      end
    end)
  end

  # The pill opens the navigator, which lives on the campaign hub — the only
  # screen where the whole tree is visible.
  def handle_event("open_branches", _params, socket) do
    case campaign_of(socket.assigns.scene_id) do
      nil -> {:noreply, socket}
      cid -> {:noreply, push_navigate(socket, to: ~p"/campaigns/#{cid}?branches=open")}
    end
  end

  # Scan the scene's committed prose for characters mentioned but not yet created,
  # and stub them for later (§B8 mention-stubbing).
  def handle_event("find_mentions", _params, socket) do
    safe(socket, fn ->
      prose = scene_prose(socket.assigns.scene_id)

      {:noreply,
       socket
       |> put_flash(:info, "Scanning for mentioned characters…")
       |> request_generation(
         "mentions",
         "play.mentions",
         Map.merge(%{prose: prose}, billing(socket))
       )}
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
  # Grounded in the **Director's omniscient view**, through `SceneBrief.recent_lines/2` —
  # the same read the Director's own judgment call conditions on, which is right because
  # Narrate commits the same `WorldEventOccurred` the Director emits, from a human.
  #
  # This used to filter the scene down to "what everybody can see", assembled here out of
  # `socket.assigns.messages` and a hand-kept list of public event kinds. Two things were
  # wrong with that. The list is `Visibility`'s job and got a new event type wrong by
  # omission rather than by default-deny; and the socket's messages are **viewer-filtered**,
  # so the context depended on which perspective the author was looking through.
  #
  # The filtering is gone deliberately: the world does not care what is secret and has to
  # know in order to stay consistent with it — a door is locked because somebody locked it
  # quietly. What keeps the secret unsaid is the prompt (a world event is seen by everyone)
  # and the author, who edits the draft before committing it.
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
            for(
              id <- socket.assigns.roster,
              do: %{"name" => Play.name_of(socket.assigns.cast, id)}
            ),
          location: elem(scene_campaign_location(socket.assigns.scene_id), 1),
          recent: SceneBrief.recent_lines(socket.assigns.scene_id),
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
      entry = if offered?(socket.assigns.joinable, id), do: Library.get(id)

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
      entry = if offered?(socket.assigns.writable, id), do: Library.get(id)

      if entry do
        {:noreply,
         socket
         |> assign(writing_in: MapSet.put(socket.assigns.writing_in, entry.id))
         |> request_generation(
           "write_in:#{entry.id}",
           "play.intro",
           Map.merge(%{entry_id: entry.id}, billing(socket))
         )}
      else
        {:noreply, put_flash(socket, :error, "They aren't waiting to be written.")}
      end
    end)
  end

  # ── The panel's own two doors (§07) ────────────────────────────────────────────
  #
  # `intros_view` is one assign rather than four booleans that can disagree, so moving
  # between the panel's faces is a single write. Nothing here touches the scene — these
  # are navigation within a panel, and the only ones that commit anything are
  # `intro_write_new` and `picker_admit`.

  def handle_event("intros_write_new", params, socket) do
    # Carries the query in from `intros_picker_empty`: somebody who searched for an
    # alchemist and found none wants an alchemist, and re-typing it is the panel making
    # them repeat themselves.
    {:noreply,
     assign(socket,
       intros_view: :write_new,
       new_name: params["name"] || socket.assigns.new_name,
       new_premise: ""
     )}
  end

  def handle_event("intros_picker", _params, socket),
    do: {:noreply, socket |> assign(intros_view: :picker, picker_query: "") |> load_picker()}

  def handle_event("picker_search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(picker_query: q) |> load_picker()}

  def handle_event("picker_tier", %{"tier" => tier}, socket),
    do: {:noreply, socket |> assign(picker_tier: tier) |> load_picker()}

  def handle_event("picker_choose", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.picker_rows, &(to_string(&1.id) == to_string(id)))
    {:noreply, assign(socket, picker_chosen: row, intros_view: :picker_confirm)}
  end

  def handle_event("intro_control", %{"control" => control}, socket),
    do: {:noreply, assign(socket, intro_control: control)}

  def handle_event("picker_admit", %{"id" => id}, socket) do
    safe(socket, fn ->
      case Library.get(id) do
        nil ->
          {:noreply, put_flash(socket, :error, "That character is gone.")}

        entry ->
          socket = set_control(socket, to_string(entry.id))
          {:noreply, admit(close_intros(socket), entry, Library.payload(entry))}
      end
    end)
  end

  # Writes them **and** brings them on. The secondary route (the sheet editor) is the
  # same character by a longer road, which is what the panel's own note promises: either
  # way they join the cast as a full character.
  def handle_event("intro_write_new", %{"name" => name} = params, socket) do
    safe(socket, fn ->
      case String.trim(name) do
        "" ->
          {:noreply, put_flash(socket, :error, "Give them a name first.")}

        name ->
          {:noreply,
           socket
           |> assign(intro_control: params["control"] || socket.assigns.intro_control)
           |> write_in_new(name, params["premise"])}
      end
    end)
  end

  # ── Somebody in the room whose sheet didn't land (`admitted_failed`) ──────────
  #
  # Three ways out and they are genuinely different, which is why they are three
  # handlers rather than a retry with decoration: run it again, write them by hand, or
  # let them leave.

  def handle_event("intro_retry", %{"id" => id}, socket) do
    safe(socket, fn ->
      case Library.get(normalize_id(id)) do
        nil ->
          {:noreply, put_flash(socket, :error, "They're gone.")}

        entry ->
          {:noreply,
           socket
           |> assign(writing_in: MapSet.put(socket.assigns.writing_in, entry.id))
           |> reload()
           |> request_generation(
             "write_in:#{entry.id}",
             "play.intro",
             Map.merge(%{entry_id: entry.id}, billing(socket))
           )}
      end
    end)
  end

  def handle_event("intro_write_self", %{"id" => id}, socket) do
    case Library.get(normalize_id(id)) do
      nil -> {:noreply, put_flash(socket, :error, "They're gone.")}
      entry -> {:noreply, push_navigate(socket, to: ~p"/authoring/character/#{entry.id}")}
    end
  end

  def handle_event("send_away_confirm", %{"id" => id}, socket) do
    {:noreply,
     assign(socket,
       sending_away: Enum.find(socket.assigns.admitted, &(to_string(&1.id) == to_string(id)))
     )}
  end

  def handle_event("send_away_cancel", _params, socket),
    do: {:noreply, assign(socket, sending_away: nil)}

  # **A departure, not an undo.** The entrance is a committed event that other characters
  # could already have reacted to, so removing them cannot mean erasing it: the fiction
  # absorbs it the same way the Director's own rulings do — a world event saying they
  # go — and then they exit. The log stays append-only, a reader who saw the entrance is
  # never shown a scene that contradicts their memory, and bringing them on again later
  # reconciles with nothing.
  def handle_event("send_away", %{"id" => id}, socket) do
    safe(socket, fn ->
      case Library.get(normalize_id(id)) do
        nil ->
          {:noreply, assign(socket, sending_away: nil)}

        entry ->
          scene_id = socket.assigns.scene_id
          beat = max(socket.assigns.next_beat - 1, 1)
          name = Cast.render_name(socket.assigns.cast, to_string(entry.id))

          :ok =
            App.dispatch(%RecordWorldEvent{
              scene_id: scene_id,
              beat: beat,
              content: "#{name} leaves the way they came."
            })

          :ok =
            App.dispatch(%ExitCharacter{
              scene_id: scene_id,
              character_id: to_string(entry.id),
              beat: beat
            })

          {:noreply,
           socket
           |> assign(
             sending_away: nil,
             writing_in: MapSet.delete(socket.assigns.writing_in, entry.id)
           )
           |> reload()}
      end
    end)
  end

  def handle_event("intro_open_editor", _params, socket) do
    safe(socket, fn ->
      name = String.trim(socket.assigns.new_name)

      if name == "" do
        {:noreply, put_flash(socket, :error, "Give them a name first.")}
      else
        entry = stub_for(socket, name, socket.assigns.new_premise)
        {:noreply, push_navigate(socket, to: ~p"/authoring/character/#{entry.id}")}
      end
    end)
  end

  def handle_event("toggle_intros", _params, socket),
    do: {:noreply, assign(socket, panel: toggle(socket.assigns.panel, :intros), narrating: false)}

  def handle_event("continue", _params, socket) do
    cond do
      Play.beat_busy?(socket.assigns.progress) ->
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

  # Auto (§10 + `Director.Auto`): the beat loop with nobody to hand back to. Runs until
  # the Director closes the scene, the room empties, or it hits the beat cap.
  def handle_event("start_auto", _params, socket) do
    safe(socket, fn ->
      scene_id = socket.assigns.scene_id
      beat = socket.assigns.next_beat

      cond do
        Play.beat_busy?(socket.assigns.progress) ->
          {:noreply, put_flash(socket, :error, "The scene is already advancing.")}

        socket.assigns.roster == [] ->
          {:noreply, put_flash(socket, :error, "No cast present to run with.")}

        true ->
          case Auto.start(scene_id, beat) do
            {:ok, run} ->
              {:noreply,
               socket
               |> assign(auto: run, progress: %{phase: :director, subject: nil, beat: beat})}

            {:error, :taken} ->
              {:noreply, put_flash(socket, :error, "It's already running itself.")}
          end
      end
    end)
  end

  def handle_event("pause_auto", _params, socket) do
    safe(socket, fn ->
      case Auto.pause(socket.assigns.scene_id) do
        {:ok, run} ->
          # The beat in flight finishes: it is already generating, and throwing it away
          # would cost the same money to produce nothing.
          {:noreply,
           socket
           |> assign(auto: run)
           |> put_flash(:info, "Pausing after this beat.")}

        {:error, :not_running} ->
          {:noreply, put_flash(socket, :error, "Nothing is running.")}
      end
    end)
  end

  def handle_event("resume_auto", _params, socket) do
    safe(socket, fn ->
      case Auto.resume(socket.assigns.scene_id, socket.assigns.next_beat) do
        {:ok, run} -> {:noreply, assign(socket, auto: run)}
        {:error, :not_paused} -> {:noreply, put_flash(socket, :error, "It isn't paused.")}
      end
    end)
  end

  # The finished line, taken off the bar. Not a delete of the run — the row is how a
  # second tab and the next mount know what happened.
  def handle_event("clear_auto", _params, socket), do: {:noreply, assign(socket, auto: nil)}

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

  # ── The gate, met on the way in (STR-62) ─────────────────────────────────────
  #
  # The cards are the review screen's own, prefixed because this screen already owns
  # an `edit`/`cancel_edit` for turns. Accept-all is the one-tap path and carries
  # straight on into the entrance it interrupted — the person who wants to play taps
  # once, which is the same promise the cast rows make.

  def handle_event("arc_accept", %{"id" => id}, socket),
    do: arc_gate_act(socket, &ArcAccept.accept(&1, Owner.of(socket.assigns.current_user)), id)

  def handle_event("arc_reject", %{"id" => id}, socket),
    do: arc_gate_act(socket, &ArcRM.reject(Repo, &1), id)

  def handle_event("arc_set_audience", %{"id" => id, "who" => who}, socket) do
    who = if who == "there", do: :there, else: :everyone
    arc_gate_act(socket, &ArcRM.set_audience(Repo, &1, who), id)
  end

  def handle_event("arc_edit", %{"id" => id}, socket),
    do: {:noreply, update_arc_gate(socket, &%{&1 | editing: String.to_integer(id)})}

  def handle_event("arc_cancel_edit", _params, socket),
    do: {:noreply, update_arc_gate(socket, &%{&1 | editing: nil})}

  def handle_event("arc_save_edit", %{"entry_id" => id} = params, socket) do
    safe(socket, fn ->
      ArcRM.edit(Repo, String.to_integer(id), %{statement: params["statement"]})
      {:noreply, socket |> update_arc_gate(&%{&1 | editing: nil}) |> refresh_arc_gate()}
    end)
  end

  def handle_event("arc_accept_all", _params, socket) do
    safe(socket, fn ->
      case socket.assigns.arc_gate do
        nil ->
          {:noreply, socket}

        gate ->
          ArcAccept.accept_all(gate.id, "character", Owner.of(socket.assigns.current_user))
          {:noreply, continue_admission(socket, gate)}
      end
    end)
  end

  def handle_event("arc_gate_continue", _params, socket) do
    safe(socket, fn ->
      case socket.assigns.arc_gate do
        nil -> {:noreply, socket}
        gate -> {:noreply, continue_admission(socket, gate)}
      end
    end)
  end

  # Backing out leaves them out of the scene and their arc where it was. Nothing was
  # half-done: the entrance never happened.
  def handle_event("arc_gate_cancel", _params, socket),
    do: {:noreply, assign(socket, arc_gate: nil, intros_view: :panel)}

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

      {:noreply,
       socket
       |> put_flash(:info, "Generating #{name}…")
       |> request_generation(
         "intro:#{name}",
         "play.intro",
         Map.merge(%{entry_id: entry.id}, billing(socket))
       )}
    end)
  end

  # ── Live events ──────────────────────────────────────────────────────────────

  # A draft landed. The beat has stopped and is waiting on a decision, so stop
  # showing it as in-flight — otherwise the composer stays blocked behind a spinner
  # for a beat that isn't going anywhere on its own.
  def handle_info({:polyphony_event, %{type: "draft.ready"}}, socket) do
    {:noreply, socket |> assign(progress: Play.idle()) |> reload()}
  end

  def handle_info({:polyphony_event, %{type: "generation.failed"}}, socket) do
    # A turn couldn't be generated — stop waiting and surface the open failure
    # (reload picks it up from the Failures store) instead of failing silently.
    {:noreply, socket |> assign(waiting: :you, progress: Play.idle()) |> reload()}
  end

  # Beat-loop activity: reflect what's running now (Director / a character / idle) so the
  # indicator is accurate and input stays blocked until the beat truly settles.
  def handle_info({:scene_progress, %{phase: phase} = p}, socket) do
    # The beat comes with it and used to be dropped. `submit_user_turn/5` needs the beat
    # the walk actually paused on — committing at `next_beat` instead is how a
    # user-controlled turn lands outside the beat that is waiting for it.
    {:noreply, assign(socket, progress: %{phase: phase, subject: p[:subject], beat: p[:beat]})}
  end

  # A re-roll/edit/delete dropped a packet. The transcript is the *only* assign a
  # supersession changes — the strip reads beat events (a supersession emits none), the
  # roster, cast, drafts and failures are all untouched — so this drops the packet's lines
  # in place rather than re-deriving the scene.
  #
  # It used to `reload/1`, which is a full stream read plus four repo reads, and a re-roll
  # emits **one of these per packet dropped**: the re-rolled turn and every turn after it
  # in the beat. So the cost was the whole scene re-read once per turn being replaced,
  # right at the moment the author is waiting to see the new one.
  def handle_info({:polyphony_event, %{type: "packet.superseded", packet_id: id}}, socket)
      when is_binary(id) do
    {:noreply,
     socket
     |> assign(messages: drop_packet(socket.assigns.messages, id))
     |> stream_beats(reset: true)}
  end

  # No `packet_id` to drop. Nothing emits this, and if something starts to, re-deriving is
  # the answer that is still correct.
  def handle_info({:polyphony_event, %{type: "packet.superseded"}}, socket) do
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
          cond do
            not match?(%CharacterSheet{status: :full}, sheet) ->
              {:noreply,
               socket
               |> reload()
               |> put_flash(:error, "Written, but not ready — open them to finish.")}

            # Already in the room: they were admitted first and this is the sheet
            # arriving underneath them, so they get the context and the brief rather
            # than a second `EnterCharacter`.
            to_string(entry.id) in Enum.map(socket.assigns.roster, &to_string/1) ->
              {:noreply, settle_admitted(socket, entry, sheet)}

            true ->
              {:noreply, admit(socket, entry, sheet)}
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
     # Reload rather than only flashing: if they were admitted first, this is the moment
     # the panel has to stop saying *being written* and offer the three ways out.
     |> reload()
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

  def handle_info({:scene_auto, run}, socket),
    do: {:noreply, socket |> assign(auto: run) |> reload()}

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
    case Play.awaiting(socket.assigns.progress) do
      {^as, beat} ->
        BeatDriver.submit_user_turn(socket.assigns.scene_id, beat, as, packet)
        socket |> assign(progress: Play.idle()) |> reload()

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
          premise = socket.assigns.premise
          sheet = character_sheet(socket, as)
          bible = campaign_world_bible(socket)

          {:noreply,
           socket
           |> assign(composing: true)
           |> request_generation("compose", "play.compose", %{
             opts:
               compose_opts(scene_id, as, sheet, premise, bible, roster, draft) ++
                 meter(socket, "suggestion")
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
  defp compose_opts(scene_id, character, sheet, premise, bible, roster, draft) do
    ctx = character_context(scene_id, character, sheet, premise, bible)

    [
      context: ctx,
      live_events: BeatOps.canonical_events(scene_id),
      members: roster,
      count: 1,
      steer: compose_steer(draft)
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
      _ -> %CharacterSheet{name: Play.name_of(socket, character_id)}
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

  # Every line decomposed from one packet carries its `packet_id`, which is what makes a
  # supersession a filter rather than a re-derivation. Matches `Broadcast.replay/4`'s own
  # rule for a reconnecting client, so the live path and the replay path drop the same set.
  defp drop_packet(messages, packet_id),
    do: Enum.reject(messages, &(get_in(&1, [:payload, :packet_id]) == packet_id))

  defp append(socket, msg) do
    seq = msg[:seq]
    existing = socket.assigns.messages

    if is_integer(seq) and Enum.any?(existing, &(&1[:seq] == seq)) do
      socket
    else
      socket |> assign(messages: existing ++ [msg]) |> stream_beats()
    end
  end

  # ── The transcript stream ─────────────────────────────────────────────────────
  #
  # The DOM unit is a **beat**, not a message and not a block. A message is a fragment of
  # a turn (a thought, a line and an action are three messages and one block), and a block
  # mutates in place as its packet's later moves arrive — so neither is a stable key. A
  # beat is: it is keyed by its own number, and it is *bounded* by the cast size, where the
  # transcript is not bounded by anything.
  #
  # So a move landing re-renders its beat rather than the scene. The cost is that the
  # newest beat re-renders once per move as it fills, which is the price of a stream unit
  # coarse enough to be stable.
  #
  # Recomputed from `messages` rather than patched in place: the tree is cheap, and a
  # second incremental implementation of grouping is how the streamed transcript and the
  # replayed one start disagreeing about what happened.
  # **Anything that changes how a beat renders has to come back through here.** That is the
  # cost of a stream and it is easy to miss: `phx-update="stream"` means the client only
  # touches nodes the server explicitly re-inserts, so assigning `editing` and re-rendering
  # is no longer enough — the beat holding that turn keeps the markup it was last sent, and
  # the edit form never appears. Found by four tests looking for a form that was not there.
  #
  # `editing` is the live one and takes the narrow door — `restream_packet/2`, one beat.
  # `register`, `cast` and `voices` also reach a turn block and only change through
  # `reload/1`, which resets the whole stream anyway.
  defp stream_beats(socket, opts \\ []) do
    beats = beat_tree(socket)

    socket
    # A stream has no emptiness to ask about — the socket knows, and the screen is handed
    # the answer rather than a collection it cannot count.
    |> assign(transcript_empty: beats == [])
    |> stream(:beats, beats, reset: Keyword.get(opts, :reset, false))
  end

  defp beat_tree(socket) do
    socket.assigns.messages
    |> Transcript.beats()
    |> Transcript.with_failures(socket.assigns.failures, max(socket.assigns.next_beat - 1, 0))
  end

  # One beat, because one turn changed how it renders — the beat holding `packet_id`.
  #
  # The alternative is `stream_beats(reset: true)`, which is what clicking Edit used to do:
  # send the whole scene to put a textarea on one turn. It also makes trimming the retained
  # messages impossible, because a reset replaces the stream with exactly what it is given —
  # so a socket holding only the recent beats would *delete* the older ones from the DOM the
  # moment somebody pressed Edit.
  #
  # The beat is rendered with the current assigns, so `editing` has to be set before this
  # runs rather than after.
  defp restream_packet(socket, nil), do: socket

  defp restream_packet(socket, packet_id) do
    case Enum.find(beat_tree(socket), fn b ->
           Enum.any?(b.blocks, &(&1.packet_id == packet_id))
         end) do
      nil -> socket
      beat -> stream_insert(socket, :beats, beat)
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
        detail: Play.failure_reason(f)
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

  # A plain-text rendering of the whole timeline, stashed hidden for the Copy button so
  # collapsed <details> content comes along too (paste-to-report friendly).
  defp feed_text(feed), do: Enum.map_join(feed, "\n\n", &entry_text/1)

  defp entry_text(%{kind: :event} = e),
    do: "[#{Play.at_label(e.at_ms)}] EVENT ##{e.seq} b#{e.beat} #{e.label}\n#{e.detail}"

  defp entry_text(%{kind: :trace} = t),
    do:
      "[#{Play.at_label(t.at_ms)}] LLM #{t.subject} · #{t.model} · #{t.outcome}\n" <>
        "params: #{t.params}\nrequest:\n#{t.request}\nresponse:\n#{t.response}"

  defp entry_text(%{kind: :error} = e),
    do: "[#{Play.at_label(e.at_ms)}] ERROR #{e.subject} b#{e.beat}\n#{e.detail}"

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

  def render(assigns) do
    ~H"""
    <Play.screen
      auto={@auto}
      campaign_name={@campaign_name}
      cast={@cast}
      composing={@composing}
      control_modes={@control_modes}
      current_user={@current_user}
      debug_events={@debug_events}
      debug_feed={@debug_feed}
      debug_feed_text={@debug_feed_text}
      debug_trace={@debug_trace}
      drafting_narration={@drafting_narration}
      drafts={@drafts}
      editing={@editing}
      editing_draft={@editing_draft}
      failures={@failures}
      introductions={@introductions}
      suggestion={@suggestion}
      intros_view={@intros_view}
      arc_gate={@arc_gate}
      intro_control={@intro_control}
      admitted={@admitted}
      sending_away={@sending_away}
      new_name={@new_name}
      new_premise={@new_premise}
      picker_query={@picker_query}
      picker_tier={@picker_tier}
      picker_rows={@picker_rows}
      picker_chosen={@picker_chosen}
      joinable={@joinable}
      beats={@streams.beats}
      transcript_empty={@transcript_empty}
      narrating={@narrating}
      narrating_draft={@narrating_draft}
      next_beat={@next_beat}
      panel={@panel}
      progress={@progress}
      register={@register}
      roster={@roster}
      scene_id={@scene_id}
      scene_title={@scene_title}
      speaker={@speaker}
      strip={@strip}
      viewer={@viewer}
      voices={@voices}
      who={@who}
      writable={@writable}
      writing_in={@writing_in}
    />
    """
  end
end
