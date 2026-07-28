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

  alias Polyphony.{App, Broadcast, MembershipSet, SceneControl}
  alias Polyphony.Director.BeatOps
  alias Polyphony.Commands.{CommitPacket, DeclareTurnOrder}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.SelfState
  alias PolyphonyWeb.SayParser

  def mount(%{"scene_id" => scene_id}, _session, socket) do
    {:ok, assign(socket, scene_id: scene_id, page_title: "Play", topic: nil, waiting: :you)}
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

    assign(socket, messages: messages, roster: roster, next_beat: next_beat)
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
