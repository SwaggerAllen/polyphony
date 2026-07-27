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
  alias Polyphony.TurnPacket.{Move, SelfState}

  def mount(%{"scene_id" => scene_id}, _session, socket) do
    {:ok, assign(socket, scene_id: scene_id, page_title: "Play", topic: nil, waiting: :you)}
  end

  # Viewer is chosen via ?as=<character> (absent → omniscient author view). Runs on
  # first load and on every viewer switch, (re)subscribing to the right topic.
  def handle_params(params, _uri, socket) do
    viewer = parse_viewer(params["as"])
    socket = resubscribe(socket, viewer)
    {:noreply, socket |> assign(viewer: viewer) |> reload()}
  end

  defp parse_viewer(as) when as in [nil, "", "omniscient"], do: :omniscient
  defp parse_viewer(as), do: {:character, as}

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

  def handle_event("say", %{"as" => as, "text" => text} = params, socket)
      when as != "" and text != "" do
    safe(socket, fn ->
      beat = socket.assigns.next_beat

      to =
        case params["to"] do
          t when t in [nil, ""] -> []
          t -> [t]
        end

      audibility = if(to == [], do: :normal, else: :private)

      packet = %TurnPacket{
        moves: [
          %Move{seq: 1, type: :speech, content: text, addressed_to: to, audibility: audibility}
        ],
        self_state: %SelfState{}
      }

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
    end)
  end

  def handle_event("say", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Pick a character and type something.")}

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
      <span class="faint">viewing as</span>
      <.viewer_link scene_id={@scene_id} viewer={@viewer} label="Omniscient" as={nil} />
      <.viewer_link :for={c <- @roster} scene_id={@scene_id} viewer={@viewer} label={c} as={c} />
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
        <div class="row">
          <select name="as" style="width:auto;">
            <option :for={c <- @roster} value={c}><%= c %></option>
          </select>
          <input type="text" name="text" placeholder="Say something…" style="flex:1;" autocomplete="off" />
          <select name="to" style="width:auto;" title="Whisper to (optional)">
            <option value="">— aloud —</option>
            <option :for={c <- @roster} value={c}>whisper: <%= c %></option>
          </select>
          <button class="btn" type="submit">Send</button>
        </div>
      </form>
      <div class="row" style="margin-top:.5rem;">
        <button class="btn ghost sm" phx-click="continue">Continue (Director)</button>
        <span class="faint">Let the autonomous cast take the next beat.</span>
      </div>
    </div>
    """
  end

  attr(:scene_id, :string, required: true)
  attr(:viewer, :any, required: true)
  attr(:label, :string, required: true)
  attr(:as, :any, required: true)

  defp viewer_link(assigns) do
    active = assigns.viewer == parse_viewer(assigns.as)
    assigns = assign(assigns, active: active)

    ~H"""
    <.link patch={~p"/play/#{@scene_id}?#{[as: @as]}"} class={"btn sm #{if @active, do: "", else: "ghost"}"}>
      <%= @label %>
    </.link>
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
