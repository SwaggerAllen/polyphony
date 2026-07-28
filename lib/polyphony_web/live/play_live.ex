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

  alias Polyphony.{App, Broadcast, Context, Library, MembershipSet, Owner, SceneControl}
  alias Polyphony.Context.Store
  alias Polyphony.Director.BeatOps
  alias Polyphony.Commands.{CommitPacket, DeclareTurnOrder, EnterCharacter, DismissIntroduction}
  alias Polyphony.Authoring.{CharacterSheet, Stub, StubGen}

  alias Polyphony.Events.{
    IntroductionProposed,
    IntroductionDismissed,
    CharacterEntered,
    SceneOpened
  }

  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.SelfState
  alias PolyphonyWeb.SayParser

  def mount(%{"scene_id" => scene_id}, _session, socket) do
    {:ok,
     assign(socket,
       scene_id: scene_id,
       page_title: "Play",
       topic: nil,
       waiting: :you,
       introductions: [],
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
    events = stored_with_seq(socket.assigns.scene_id)
    plain = Enum.map(events, &elem(&1, 1))
    member_at? = plain |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    messages = Broadcast.replay(events, socket.assigns.viewer, member_at?, 0)

    next_beat = 1 + Enum.max([0 | Enum.map(plain, &event_beat/1)])
    roster = BeatOps.members_now(socket.assigns.scene_id, max(next_beat - 1, 1))

    assign(socket,
      messages: messages,
      roster: roster,
      next_beat: next_beat,
      premise: scene_premise(plain),
      # The Director's pending introductions — author-facing tooling, so only the
      # omniscient view shows the queue (and each carries how it resolves).
      introductions: intro_queue(socket, plain)
    )
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
    seed_context(scene_id, name, sheet, socket.assigns.premise)
    socket |> reload() |> put_flash(:info, "#{name} joins the scene.")
  end

  defp admit(socket, name, _other),
    do: put_flash(socket, :error, "#{name} has no usable sheet yet.")

  defp seed_context(scene_id, name, %CharacterSheet{} = sheet, premise) do
    ctx =
      Context.materialize(scene_id: scene_id, character_id: name, sheet: sheet, premise: premise)

    Store.put(scene_id, name, ctx)
  end

  defp seed_context(_scene_id, _name, _other, _premise), do: :ok

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
    safe(socket, fn ->
      case {socket.assigns.speaker, SayParser.parse(text)} do
        {nil, _} ->
          {:noreply, put_flash(socket, :error, "Switch to a character above to speak.")}

        {_as, []} ->
          {:noreply, put_flash(socket, :error, "Type something to say.")}

        {as, moves} ->
          beat = socket.assigns.next_beat
          packet = %TurnPacket{moves: moves, self_state: %SelfState{}}

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

  def handle_event("say", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Type something to say.")}

  def handle_event("view_as", %{"as" => as}, socket) do
    scene_id = socket.assigns.scene_id
    to = if as in [nil, ""], do: ~p"/play/#{scene_id}", else: ~p"/play/#{scene_id}?#{[as: as]}"
    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("continue", _params, socket) do
    safe(socket, fn ->
      scene_id = socket.assigns.scene_id
      beat = socket.assigns.next_beat
      roster = socket.assigns.roster

      if roster == [] do
        {:noreply, put_flash(socket, :error, "No cast present to continue with.")}
      else
        # Declare the beat's turn order (roster order), then let the Oban Director loop
        # cast the autonomous members. Events stream back over the broadcaster.
        :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene_id, beat: beat, order: roster})
        SceneControl.continue(scene_id, beat, args: %{"control_hint" => "yield_to_user"})
        {:noreply, socket |> assign(waiting: :director, next_beat: beat + 1)}
      end
    end)
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

  def handle_info({:polyphony_event, msg}, socket) do
    socket =
      case msg do
        %{kind: "BeatClosed"} -> assign(socket, waiting: :you)
        _ -> socket
      end

    {:noreply, append(socket, msg)}
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

  # ── Render ─────────────────────────────────────────────────────────────────────

  def render(assigns) do
    ~H"""
    <div class="row">
      <h1>Scene</h1>
      <div class="spacer"></div>
      <form id="viewer-form" phx-change="view_as">
        <label class="faint" style="display:inline; margin-right:.4rem;">Viewing as</label>
        <select name="as" style="width:auto;">
          <option value="" selected={@viewer == :omniscient}>Omniscient</option>
          <option :for={c <- @roster} value={c} selected={@viewer == {:character, c}}><%= c %></option>
        </select>
      </form>
    </div>

    <div class="card" style="padding:0;overflow:hidden;">
      <div id="transcript" class="transcript" phx-hook="Autoscroll">
        <div :for={{m, i} <- Enum.with_index(@messages)} id={"m-#{m[:seq] || "x"}-#{i}"}>
          <%= render_move(m) %>
        </div>
      </div>
    </div>

    <div :if={@introductions != []} class="card intro-queue">
      <h3>The Director wants to bring characters on</h3>
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

    <%= case @waiting do %>
      <% :director -> %><.waiting state="director" label="The Director is casting…" />
      <% _ -> %><.waiting state="you" label="Your move." />
    <% end %>

    <div class="composer card">
      <form phx-submit="say">
        <textarea
          :if={@speaker}
          id="say-input"
          name="text"
          rows="1"
          class="say-input"
          phx-hook="ComposerInput"
          autocomplete="off"
          placeholder={"Speak as #{@speaker}…  ·  whisper with (whisper to NAME: …)"}
        ></textarea>
        <div class="row" style="margin-top:.5rem;">
          <span :if={@speaker} class="faint">
            Speaking as <strong><%= @speaker %></strong> · Enter to send, Shift+Enter for a new line
          </span>
          <span :if={is_nil(@speaker)} class="faint">Viewing as omniscient — pick a character above to speak.</span>
          <div class="spacer"></div>
          <button :if={@speaker} class="btn" type="submit">Send</button>
        </div>
      </form>
      <hr class="sep" />
      <div class="row">
        <button class="btn ghost sm" phx-click="continue">Continue (Director)</button>
        <span class="faint">Let the autonomous cast take the next beat.</span>
      </div>
    </div>
    """
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
    assigns = %{p: p}
    ~H|<div class="move action"><%= @p[:character_id] %> <%= @p[:content] %></div>|
  end

  defp render_move(%{kind: "WorldEventOccurred", payload: p}) do
    assigns = %{p: p}
    ~H|<div class="move world"><%= @p[:content] %></div>|
  end

  defp render_move(%{kind: "DemeanorReported", payload: p}) do
    assigns = %{p: p}
    ~H|<div class="move action"><%= @p[:character_id] %> seems <%= @p[:demeanor] %>.</div>|
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
