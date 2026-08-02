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
  """
  use PolyphonyWeb, :live_view

  alias Polyphony.{
    App,
    Broadcast,
    Context,
    DebugFlags,
    Failures,
    Library,
    MembershipSet,
    Owner,
    SceneControl,
    Suggest,
    TurnOrder
  }

  alias Polyphony.Context.{Store, PgvectorRetriever}
  alias Polyphony.DebugTap
  alias Polyphony.Director.{BeatOps, SceneBrief}

  alias Polyphony.Commands.{
    CommitPacket,
    DeclareTurnOrder,
    EnterCharacter,
    DismissIntroduction,
    SetControlMode,
    SupersedePacket
  }

  alias Polyphony.Authoring.{Autofill, CharacterSheet, Stub, StubGen}

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
    if connected?(socket) do
      DebugFlags.subscribe()
      DebugTap.subscribe(scene_id)
      # Beat-loop activity (Director deciding / who's generating / idle) — every viewer
      # subscribes so the indicator is accurate and input can be blocked while a beat runs.
      Phoenix.PubSub.subscribe(Polyphony.PubSub, Broadcast.progress_topic(scene_id))
    end

    {:ok,
     assign(socket,
       scene_id: scene_id,
       page_title: "Play",
       topic: nil,
       waiting: :you,
       progress: %{phase: :idle, subject: nil},
       introductions: [],
       control_modes: %{},
       failures: [],
       editing: nil,
       composing: false,
       debug_events: DebugFlags.get(:events),
       debug_trace: DebugFlags.get(:trace),
       raw_events: [],
       traces: [],
       debug_feed: [],
       debug_feed_text: "",
       premise: ""
     )}
  end

  # Viewer is chosen via ?as=<character> (absent → omniscient author view). Runs on
  # first load and on every viewer switch, (re)subscribing to the right topic.
  def handle_params(params, _uri, socket) do
    viewer = parse_viewer(params["as"])
    socket = resubscribe(socket, viewer)
    {:noreply, socket |> assign(viewer: viewer, speaker: speaker(viewer)) |> reload()}
  end

  defp parse_viewer(as) when as in [nil, "", "omniscient"], do: :omniscient
  defp parse_viewer(as), do: {:character, as}

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
    roster = BeatOps.members_now(scene_id, max(next_beat - 1, 1))

    traces = if socket.assigns.debug_trace, do: DebugTap.recent(scene_id), else: []
    failures = open_failures(socket)
    feed = debug_feed(socket, traces, failures)

    assign(socket,
      messages: messages,
      raw_events: events,
      traces: traces,
      roster: roster,
      next_beat: next_beat,
      premise: scene_premise(plain),
      control_modes: Map.new(roster, fn c -> {c, TurnOrder.control_mode(plain, c)} end),
      # The Director's pending introductions — author-facing tooling, so only the
      # omniscient view shows the queue (and each carries how it resolves).
      introductions: intro_queue(socket, plain),
      failures: failures,
      debug_feed: feed,
      debug_feed_text: feed_text(feed)
    )
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

  defp scene_premise(plain) do
    Enum.find_value(plain, "", fn
      %SceneOpened{premise: p} -> p || ""
      _ -> nil
    end)
  end

  defp intro_queue(socket, plain) do
    if socket.assigns.viewer == :omniscient do
      by_name = owner_characters(socket.assigns.current_user)

      plain
      |> pending_introductions()
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
  defp pending_introductions(plain) do
    plain
    |> Enum.reduce(%{}, fn
      %IntroductionProposed{name: n} = e, acc ->
        Map.put(acc, String.downcase(n), %{name: n, reason: e.reason, beat: e.beat})

      %IntroductionDismissed{name: n}, acc ->
        Map.delete(acc, String.downcase(n))

      %CharacterEntered{character_id: c}, acc ->
        Map.delete(acc, String.downcase(to_string(c)))

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
    members = MapSet.new(socket.assigns.roster, &String.downcase(to_string(&1)))
    owner = Owner.of(socket.assigns.current_user)
    world_id = campaign_world_id(socket)

    for name <- names,
        key = String.downcase(name),
        not Map.has_key?(known, key),
        not MapSet.member?(members, key) do
      Library.put(%{
        owner: owner,
        kind: "character",
        payload: Stub.new(name, "", world_bible_id: world_id)
      })

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
        Library.put(%{
          owner: Owner.of(socket.assigns.current_user),
          kind: "character",
          payload: Stub.new(name, "", world_bible_id: campaign_world_id(socket))
        })

      entry ->
        entry
    end
  end

  # Enter a finalized character into the scene at the current beat boundary and seed
  # their frozen context so the Director loop can cast them next.
  defp admit(socket, name, %CharacterSheet{} = sheet) do
    scene_id = socket.assigns.scene_id
    beat = max(socket.assigns.next_beat - 1, 1)
    :ok = App.dispatch(%EnterCharacter{scene_id: scene_id, character_id: name, beat: beat})
    seed_context(scene_id, name, sheet, socket.assigns.premise, campaign_world_bible(socket))
    # Fold the newcomer into the Director's omniscient brief so the next beat knows them.
    SceneBrief.note_character(scene_id, sheet)
    socket |> reload() |> put_flash(:info, "#{name} joins the scene.")
  end

  defp admit(socket, name, _other),
    do: put_flash(socket, :error, "#{name} has no usable sheet yet.")

  defp seed_context(scene_id, name, %CharacterSheet{} = sheet, premise, bible) do
    ctx =
      Context.materialize(
        scene_id: scene_id,
        character_id: name,
        sheet: sheet,
        premise: premise,
        world_bible: bible,
        # Retrieve this character's own distant-scene summaries from pgvector
        # (no-ops to [] without egress / when the embed fails).
        retriever: PgvectorRetriever
      )

    Store.put(scene_id, name, ctx)
  end

  defp seed_context(_scene_id, _name, _other, _premise, _bible), do: :ok

  # The scene's world bible payload (a `%WorldBible{}`), or nil — for framing both
  # the admitted character's context and the Director's omniscient brief.
  defp campaign_world_bible(socket) do
    case campaign_world_id(socket) do
      nil -> nil
      wid -> Library.get(wid) |> maybe_payload()
    end
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
       |> put_flash(:info, "Rerolling #{c}…")
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

      {:noreply, socket |> put_flash(:info, "Removed #{c}'s turn.") |> reload()}
    end)
  end

  def handle_event("edit_turn", %{"packet" => pid}, socket),
    do: {:noreply, assign(socket, editing: pid)}

  def handle_event("cancel_edit", _params, socket), do: {:noreply, assign(socket, editing: nil)}

  # Save an edit: supersede the old take and commit the author's rewrite as a new
  # attempt (same aloud/whisper inference as the composer).
  def handle_event(
        "save_edit",
        %{"beat" => b, "character" => c, "packet" => pid} = params,
        socket
      ) do
    safe(socket, fn ->
      scene = socket.assigns.scene_id
      beat = String.to_integer(b)

      case TurnEdit.parse(params["text"] || "") do
        {[], _self_state} ->
          {:noreply, put_flash(socket, :error, "The turn can't be empty.")}

        {moves, self_state} ->
          attempt = BeatOps.next_attempt(BeatOps.stored_events(scene), scene, beat, c)
          new_id = BeatOps.reroll_packet_id(scene, beat, c, attempt)

          :ok =
            App.dispatch(%SupersedePacket{
              scene_id: scene,
              beat: beat,
              character_id: c,
              packet_id: pid,
              attempt: attempt,
              reason: "edited by author"
            })

          :ok =
            App.dispatch(%CommitPacket{
              scene_id: scene,
              character_id: c,
              beat: beat,
              packet_id: new_id,
              packet: %TurnPacket{moves: moves, self_state: self_state},
              edited: true
            })

          {:noreply,
           socket |> assign(editing: nil) |> put_flash(:info, "Updated #{c}'s turn.") |> reload()}
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
       |> start_async(:mentions, fn -> Autofill.extract_mentions(prose, user_id: uid) end)}
    end)
  end

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

  def handle_event("intro_admit", %{"name" => name}, socket) do
    safe(socket, fn ->
      case find_owned(socket, name) do
        {:full, entry} ->
          {:noreply, admit(socket, name, Library.payload(entry))}

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
       |> start_async({:intro_gen, name}, fn -> StubGen.finalize(entry, uid) end)}
    end)
  end

  # ── Live events ──────────────────────────────────────────────────────────────

  def handle_info({:polyphony_event, %{type: "generation.failed"}}, socket) do
    # A turn couldn't be generated — stop waiting and surface the open failure
    # (reload picks it up from the Failures store) instead of failing silently.
    {:noreply, socket |> assign(waiting: :you, progress: idle()) |> reload()}
  end

  # Beat-loop activity: reflect what's running now (Director / a character / idle) so the
  # indicator is accurate and input stays blocked until the beat truly settles.
  def handle_info({:scene_progress, %{phase: phase} = p}, socket) do
    {:noreply, assign(socket, progress: %{phase: phase, subject: p[:subject]})}
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

  def handle_info(_other, socket), do: {:noreply, socket}

  # A just-generated introduction is now :full — admit them.
  def handle_async({:intro_gen, name}, {:ok, :ok}, socket) do
    safe(socket, fn ->
      case find_owned(socket, name) do
        {:full, entry} ->
          {:noreply, admit(socket, name, Library.payload(entry))}

        _ ->
          {:noreply,
           put_flash(socket, :error, "Generated #{name}, but they're not ready — open them.")}
      end
    end)
  end

  def handle_async({:intro_gen, name}, _result, socket) do
    {:noreply,
     put_flash(socket, :error, "Couldn't generate #{name} — open them to finish manually.")}
  end

  def handle_async(:mentions, {:ok, {:ok, names}}, socket) do
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

  def handle_async(:mentions, _result, socket),
    do: {:noreply, put_flash(socket, :error, "Couldn't scan for mentioned characters.")}

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

  def handle_async(:compose, {:ok, {:ok, [packet | _]}}, socket) do
    text = TurnEdit.serialize_packet(packet)
    {:noreply, socket |> assign(composing: false) |> push_event("set_composer", %{text: text})}
  end

  def handle_async(:compose, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(composing: false) |> put_flash(:error, compose_error(reason))}
  end

  # The async task itself crashed (e.g. a raise in the generation path).
  def handle_async(:compose, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(composing: false)
     |> put_flash(:error, "The draft crashed: #{short_reason(reason)}. Try again.")}
  end

  def handle_async(:compose, _result, socket) do
    {:noreply,
     socket |> assign(composing: false) |> put_flash(:error, "Couldn't draft a turn. Try again.")}
  end

  # Commit the player's typed turn (§A1). Grouped here (not among the handle_events) so
  # the two "say" clauses stay adjacent.
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
          beat = socket.assigns.next_beat
          packet = %TurnPacket{moves: moves, self_state: self_state}

          :ok =
            App.dispatch(%CommitPacket{
              scene_id: socket.assigns.scene_id,
              character_id: as,
              beat: beat,
              packet_id: BeatOps.packet_id(socket.assigns.scene_id, beat, as),
              packet: packet,
              edited: true
            })

          {:noreply, socket |> assign(next_beat: beat + 1) |> reload()}
      end
    end)
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
           |> start_async(:compose, fn ->
             compose_draft(scene_id, as, sheet, premise, bible, roster, draft, user)
           end)}
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
  defp compose_draft(scene_id, character, sheet, premise, bible, roster, draft, user) do
    ctx = character_context(scene_id, character, sheet, premise, bible)

    Suggest.variants(
      context: ctx,
      live_events: BeatOps.canonical_events(scene_id),
      members: roster,
      count: 1,
      steer: compose_steer(draft),
      user_id: user && user.id,
      usage_kind: "suggestion"
    )
  end

  # The character's frozen context — from the cache, or **rebuilt and re-cached on a
  # miss**. The ETS cache is cold after a restart (it's pure cache, rebuildable from
  # the sheet + log), so a miss must not fail the draft.
  defp character_context(scene_id, character, sheet, premise, bible) do
    case Store.fetch(scene_id, character) do
      {:ok, ctx} ->
        ctx

      :error ->
        ctx =
          Context.materialize(
            scene_id: scene_id,
            character_id: character,
            sheet: sheet,
            premise: premise,
            world_bible: bible,
            retriever: PgvectorRetriever
          )

        Store.put(scene_id, character, ctx)
        ctx
    end
  end

  # Resolve the acting character's sheet from the author's library by name, falling
  # back to a name-only sheet so a draft still works for a character with no full sheet.
  defp character_sheet(socket, name) do
    key = String.downcase(to_string(name))

    case Map.get(owner_characters(socket.assigns.current_user), key) do
      %{} = entry ->
        case Library.payload(entry) do
          %CharacterSheet{} = sheet -> sheet
          _ -> %CharacterSheet{name: to_string(name)}
        end

      _ ->
        %CharacterSheet{name: to_string(name)}
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

  # A character's control mode, defaulting to autonomous (matches the beat walk).
  defp control_of(modes, character), do: Map.get(modes, character) || "autonomous"

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
    {blocks, _} =
      messages
      |> turn_blocks()
      |> Enum.map_reduce(0, fn b, last ->
        eff = b.beat || last
        {Map.put(b, :eff_beat, eff), eff}
      end)

    items = Enum.map(blocks, &{:block, &1}) ++ Enum.map(failures, &{:fail, &1})

    Enum.sort_by(items, fn
      {:block, b} -> {b.eff_beat, 0}
      {:fail, f} -> {f.beat || current_beat, 1}
    end)
  end

  defp turn_blocks(messages) do
    messages
    |> Enum.reduce([], fn m, acc ->
      payload = m[:payload] || %{}
      pid = payload[:packet_id]

      case acc do
        [%{type: :turn, packet_id: ^pid} = head | rest] when not is_nil(pid) ->
          [%{head | msgs: head.msgs ++ [m]} | rest]

        _ when is_nil(pid) ->
          [%{type: :event, packet_id: nil, character: nil, beat: nil, msgs: [m]} | acc]

        _ ->
          [
            %{
              type: :turn,
              packet_id: pid,
              character: payload[:character_id] || payload[:speaker_id],
              beat: payload[:beat],
              msgs: [m]
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  # The editable text of a turn: the whole turn — thoughts, speech, actions, and
  # demeanor — serialized one move per line (see `TurnEdit`), not just its spoken lines.
  defp turn_text(block), do: TurnEdit.serialize(block.msgs)

  # ── Beat-loop progress ─────────────────────────────────────────────────────────

  defp idle, do: %{phase: :idle, subject: nil}

  # "Busy" for the sake of blocking input: a beat is actively running (the Director is
  # deciding, or a character is generating). `:awaiting_user` is *not* busy — that's the
  # user's own slot — and `:idle` means the loop has settled.
  defp beat_busy?(%{phase: phase}), do: phase in [:director, :generating]
  defp beat_busy?(_), do: false

  # The `.waiting` CSS variant (dot colour): the Director is accent-2, a cast turn accent.
  defp progress_state(%{phase: :generating}), do: "cast"
  defp progress_state(_), do: "director"

  defp progress_label(%{phase: :director}), do: "The director is setting the scene…"

  defp progress_label(%{phase: :generating, subject: c}) when is_binary(c) and c != "",
    do: "#{c} is writing their turn…"

  defp progress_label(%{phase: :generating}), do: "A character is writing their turn…"

  defp progress_label(%{phase: :awaiting_user, subject: c}) when is_binary(c) and c != "",
    do: "Waiting for you to write #{c}…"

  defp progress_label(_), do: "Working…"

  # A short, human reason for a failure line — the model's reason if any, else the kind.
  defp failure_reason(%{reason: r}) when is_binary(r) and r != "", do: r
  defp failure_reason(%{kind: k}) when is_binary(k) and k != "", do: String.replace(k, "_", " ")
  defp failure_reason(_), do: "generation failed"

  # ── Render ─────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <div class="play">
      <div class="row play-head">
        <h1>Scene</h1>
        <button
          :if={@viewer == :omniscient and (@debug_events or @debug_trace)}
          id="scene-debug-copy-btn"
          type="button"
          class="btn ghost sm"
          phx-hook="CopyText"
          data-copy-target="scene-debug-copy"
          title="Copy the debug timeline to paste elsewhere"
        >Copy debug</button>
        <div class="spacer"></div>
        <form id="viewer-form" phx-change="view_as">
          <label class="faint" style="display:inline; margin-right:.4rem;">Viewing as</label>
          <select name="as" style="width:auto;">
            <option value="" selected={@viewer == :omniscient}>Omniscient</option>
            <option :for={c <- @roster} value={c} selected={@viewer == {:character, c}}><%= c %></option>
          </select>
        </form>
      </div>

      <details :if={@viewer == :omniscient and @roster != []} class="card cast-panel">
        <summary>Cast &amp; control <span class="faint">— who drives each character</span></summary>
        <ul class="rel-list">
          <li :for={c <- @roster} class="row rel-item">
            <span><%= c %></span>
            <span class="spacer"></span>
            <form id={"control-#{c}"} phx-change="set_control">
              <input type="hidden" name="character" value={c} />
              <select name="control" style="width:auto;">
                <option value="autonomous" selected={control_of(@control_modes, c) == "autonomous"}>Automated</option>
                <option value="assisted" selected={control_of(@control_modes, c) == "assisted"}>Draft &amp; approve</option>
                <option value="user_controlled" selected={control_of(@control_modes, c) == "user_controlled"}>I write their turns</option>
              </select>
            </form>
          </li>
        </ul>
        <div class="row" style="margin-top:.5rem;">
          <button class="btn ghost sm" type="button" phx-click="find_mentions">Find mentioned characters</button>
          <span class="faint">Stub anyone named in the scene who doesn't exist yet.</span>
        </div>
      </details>

      <div class="card transcript-card">
        <div id="transcript" class="transcript" phx-hook="Autoscroll">
          <%= if @viewer == :omniscient and (@debug_events or @debug_trace) do %>
            <div class="dbg-head faint">
              Debug timeline — <%= length(@debug_feed) %> entries
              <span class="faint">· raw event stream + LLM calls + errors, oldest first (UTC)</span>
            </div>
            <pre id="scene-debug-copy" hidden><%= @debug_feed_text %></pre>
            <div id="debug-timeline">
              <div :for={entry <- @debug_feed} class={"dbg-entry dbg-#{entry.kind}"}>
                <%= render_debug_entry(entry) %>
              </div>
            </div>
          <% else %>
          <%= for {item, i} <- Enum.with_index(transcript_items(@messages, @failures, max(@next_beat - 1, 0))) do %>
            <%= case item do %>
              <% {:block, block} -> %>
                <div id={"blk-#{i}"} class="turn-block">
                  <div :for={m <- block.msgs}><%= render_move(m) %></div>

                  <div
                    :if={@viewer == :omniscient and block.type == :turn and @editing != block.packet_id}
                    class="turn-controls"
                  >
                    <button class="btn ghost xs" phx-click="reroll_turn" phx-value-beat={block.beat} phx-value-character={block.character}>Reroll</button>
                    <button class="btn ghost xs" phx-click="edit_turn" phx-value-packet={block.packet_id}>Edit</button>
                    <button class="btn danger xs" phx-click="delete_turn" phx-value-beat={block.beat} phx-value-character={block.character} phx-value-packet={block.packet_id} data-confirm="Remove this turn?">Delete</button>
                  </div>

                  <form
                    :if={@viewer == :omniscient and block.type == :turn and @editing == block.packet_id}
                    id={"edit-#{block.packet_id}"}
                    phx-submit="save_edit"
                    class="turn-edit"
                  >
                    <input type="hidden" name="beat" value={block.beat} />
                    <input type="hidden" name="character" value={block.character} />
                    <input type="hidden" name="packet" value={block.packet_id} />
                    <textarea name="text" rows="2" class="say-input"><%= turn_text(block) %></textarea>
                    <div class="row" style="margin-top:.35rem;">
                      <button class="btn xs" type="submit">Save</button>
                      <button class="btn ghost xs" type="button" phx-click="cancel_edit">Cancel</button>
                    </div>
                  </form>
                </div>
              <% {:fail, f} -> %>
                <div id={"fail-#{i}"} class="turn-block turn-fail">
                  <span>⚠ Couldn't generate <strong><%= f.subject || "a turn" %></strong>
                    <span class="faint">— <%= failure_reason(f) %></span></span>
                  <div :if={f.retryable} class="row" style="margin-top:.35rem;">
                    <button class="btn sm" phx-click="retry_failure" phx-value-id={f.id}>Retry</button>
                  </div>
                </div>
            <% end %>
          <% end %>
          <% end %>
        </div>
      </div>

      <div :if={@introductions != []} class="card intro-queue">
        <h3>New characters to bring on</h3>
        <ul class="rel-list">
          <li :for={i <- @introductions} class="row rel-item">
            <span>
              <strong><%= i.name %></strong>
              <span :if={i.reason not in [nil, ""]} class="faint">— <%= i.reason %></span>
              <span :if={i.resolution.status == :stub} class="badge stub">pending</span>
              <span :if={i.resolution.status == :new} class="badge stub">new</span>
            </span>
            <span class="spacer"></span>
            <button :if={i.resolution.status == :ready} class="btn sm" phx-click="intro_admit" phx-value-name={i.name}>Admit</button>
            <button :if={i.resolution.status != :ready} class="btn sm" phx-click="intro_generate" phx-value-name={i.name}>Generate &amp; admit</button>
            <button class="btn ghost sm" phx-click="intro_edit" phx-value-name={i.name}>Edit</button>
            <button class="btn danger sm" phx-click="intro_dismiss" phx-value-name={i.name}>Dismiss</button>
          </li>
        </ul>
      </div>

      <div class="composer card">
        <.waiting :if={beat_busy?(@progress)} state={progress_state(@progress)} label={progress_label(@progress)} />
        <.waiting :if={not beat_busy?(@progress) and @waiting == :director} state="director" label="Rerolling…" />
        <form id="say-form" phx-submit="say">
          <textarea
            :if={@speaker}
            id="say-input"
            name="text"
            rows="1"
            class="say-input"
            phx-hook="ComposerInput"
            phx-update="ignore"
            autocomplete="off"
            placeholder={"Speak as #{@speaker}…  ·  whisper with (whisper to NAME: …)"}
          ></textarea>
          <div class="row composer-actions">
            <span :if={@speaker} class="faint">as <strong><%= @speaker %></strong></span>
            <span :if={is_nil(@speaker)} class="faint">Pick a character above to speak.</span>
            <div class="spacer"></div>
            <button
              :if={@speaker}
              type="button"
              class="btn ghost sm"
              data-composer-expand="true"
              disabled={@composing or beat_busy?(@progress)}
              title="Draft or expand this turn for you — you can edit it before sending"
            >
              <%= if @composing, do: "✨ …", else: "✨ Expand" %>
            </button>
            <button class="btn ghost sm" type="button" phx-click="continue" disabled={beat_busy?(@progress)}>Continue</button>
            <button :if={@speaker} class="btn" type="submit" disabled={beat_busy?(@progress)}>Send</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

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

  # An action reads as narration: prepend the actor's name only if the content doesn't
  # already begin with it, so third-person model output isn't doubled.
  defp action_text(name, content) do
    trimmed = String.trim_leading(content)

    if name != "" and String.starts_with?(String.downcase(trimmed), String.downcase(name)),
      do: trimmed,
      else: String.trim("#{name} #{trimmed}")
  end

  # Render a broadcaster message (kind + payload with atom keys) as a transcript line.
  defp render_move(%{kind: "SpeechUttered", payload: p}) do
    assigns = %{p: p, whisper: to_string(p[:audibility]) == "private"}

    ~H"""
    <div class={"move speech #{if @whisper, do: "whisper"}"}>
      <span class="who"><%= @p[:speaker_id] %>:</span> <%= @p[:content] %>
    </div>
    """
  end

  defp render_move(%{kind: "ThoughtOccurred", payload: p}) do
    assigns = %{p: p}
    ~H|<div class="move thought">(<%= @p[:character_id] %> thinks: <%= @p[:content] %>)</div>|
  end

  defp render_move(%{kind: "ActionTaken", payload: p}) do
    # Actions are narration, not dialogue — italic prose, no "Name:" prefix. The model
    # writes them in the third person already naming the actor ("Todd snaps his head…"),
    # so prefixing the name unconditionally produced "Todd Todd …"; only prepend it when
    # the content doesn't already open with it (e.g. a first-person "I reach out…").
    assigns = %{text: action_text(to_string(p[:character_id]), to_string(p[:content]))}
    ~H|<div class="move action"><%= @text %></div>|
  end

  defp render_move(%{kind: "WorldEventOccurred", payload: p}) do
    assigns = %{p: p}
    ~H|<div class="move world"><%= @p[:content] %></div>|
  end

  defp render_move(%{kind: "DemeanorReported", payload: p}) do
    case String.trim(to_string(p[:demeanor] || "")) do
      "" ->
        # No demeanor to report — render nothing rather than "X seems ."
        assigns = %{}
        ~H||

      demeanor ->
        assigns = %{p: p, demeanor: demeanor}
        ~H|<div class="move action"><%= @p[:character_id] %> seems <%= @demeanor %>.</div>|
    end
  end

  defp render_move(%{kind: kind, payload: p})
       when kind in ["CharacterEntered", "CharacterExited"] do
    verb = if kind == "CharacterEntered", do: "enters", else: "leaves"
    assigns = %{p: p, verb: verb}
    ~H|<div class="move action">(<%= @p[:character_id] %> <%= @verb %>)</div>|
  end

  defp render_move(_other) do
    assigns = %{}
    ~H||
  end
end
