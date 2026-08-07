defmodule PolyphonyCore.Scene do
  @moduledoc """
  The Scene aggregate — arbiter of scene lifecycle and membership (§6.5).

  It owns the facts that change visibility for everyone: who is a member and
  when. A character owns their position *within* a scene (freeform, uncontested,
  carried on `DemeanorReported`); the scene owns *membership*, which must be
  arbitrated because it changes what everyone can witness (§6.3 "Location is
  dual").

  No LLM call ever happens here (rule 1): Commanded rebuilds this state by
  replaying events, so a generation inside `execute/2` would re-fire on every
  replay. Generation lives in jobs that *produce* these commands.
  """

  alias PolyphonyCore.Commands.{
    OpenScene,
    CloseScene,
    EnterCharacter,
    ExitCharacter,
    CommitPacket,
    SupersedePacket,
    ForkScene,
    SetControlMode,
    DeclareTurnOrder,
    RecordWorldEvent,
    ProposeIntroduction,
    DismissIntroduction
  }

  alias PolyphonyCore.Events.{
    SceneOpened,
    SceneClosed,
    CharacterEntered,
    CharacterExited,
    ThoughtOccurred,
    SpeechUttered,
    ActionTaken,
    PrivateStateReported,
    DemeanorReported,
    PacketSuperseded,
    SceneForked,
    ControlModeSet,
    TurnOrderDeclared,
    WorldEventOccurred,
    IntroductionProposed,
    IntroductionDismissed
  }

  alias PolyphonyCore.TurnPacket

  @type status :: :pending | :open | :closed

  defstruct scene_id: nil,
            status: :pending,
            campaign_id: nil,
            location_id: nil,
            members: MapSet.new(),
            committed_packets: MapSet.new(),
            superseded_packets: MapSet.new(),
            pending_introductions: MapSet.new(),
            forked_from: nil

  # ── Command handlers ──────────────────────────────────────────────────────

  def execute(%__MODULE__{status: :pending}, %OpenScene{} = c) do
    %SceneOpened{
      scene_id: c.scene_id,
      campaign_id: c.campaign_id,
      location_id: c.location_id,
      premise: c.premise,
      opened_beat: c.opened_beat
    }
  end

  def execute(%__MODULE__{}, %OpenScene{}), do: {:error, :scene_already_opened}

  def execute(%__MODULE__{status: :open, members: members}, %EnterCharacter{} = c) do
    if MapSet.member?(members, c.character_id) do
      {:error, :already_present}
    else
      %CharacterEntered{scene_id: c.scene_id, character_id: c.character_id, beat: c.beat}
    end
  end

  def execute(%__MODULE__{}, %EnterCharacter{}), do: {:error, :scene_not_open}

  def execute(%__MODULE__{status: :open, members: members}, %ExitCharacter{} = c) do
    if MapSet.member?(members, c.character_id) do
      %CharacterExited{scene_id: c.scene_id, character_id: c.character_id, beat: c.beat}
    else
      {:error, :not_present}
    end
  end

  def execute(%__MODULE__{}, %ExitCharacter{}), do: {:error, :scene_not_open}

  def execute(%__MODULE__{status: :open} = state, %CloseScene{} = c) do
    exits =
      state.members
      |> Enum.sort()
      |> Enum.map(&%CharacterExited{scene_id: c.scene_id, character_id: &1, beat: c.closed_beat})

    exits ++ [%SceneClosed{scene_id: c.scene_id, closed_beat: c.closed_beat}]
  end

  def execute(%__MODULE__{}, %CloseScene{}), do: {:error, :scene_not_open}

  def execute(%__MODULE__{status: :open}, %RecordWorldEvent{} = c) do
    %WorldEventOccurred{scene_id: c.scene_id, beat: c.beat, content: c.content}
  end

  def execute(%__MODULE__{}, %RecordWorldEvent{}), do: {:error, :scene_not_open}

  # A Director introduction proposal — omniscient-only queue signal, not membership.
  # Idempotent: a name already present, or already pending, is a no-op (so a retried
  # or repeated beat can't stack duplicates).
  def execute(%__MODULE__{status: :open} = state, %ProposeIntroduction{} = c) do
    cond do
      MapSet.member?(state.members, c.name) ->
        {:error, :already_present}

      MapSet.member?(state.pending_introductions, norm(c.name)) ->
        []

      norm(c.name) == "" ->
        {:error, :blank_name}

      true ->
        %IntroductionProposed{scene_id: c.scene_id, beat: c.beat, name: c.name, reason: c.reason}
    end
  end

  def execute(%__MODULE__{}, %ProposeIntroduction{}), do: {:error, :scene_not_open}

  def execute(%__MODULE__{} = state, %DismissIntroduction{} = c) do
    if MapSet.member?(state.pending_introductions, norm(c.name)),
      do: %IntroductionDismissed{scene_id: c.scene_id, name: c.name},
      else: []
  end

  # CommitPacket needs two guards (idempotency + membership) plus decomposition.
  def execute(%__MODULE__{} = state, %CommitPacket{} = c) do
    cond do
      c.packet_id != nil and MapSet.member?(state.committed_packets, c.packet_id) ->
        # Idempotent replay (§12): API succeeded, job crashed, retried. No-op.
        []

      state.status != :open ->
        {:error, :scene_not_open}

      not MapSet.member?(state.members, c.character_id) ->
        {:error, :not_a_member}

      true ->
        decompose(c)
    end
  end

  # Supersede a committed packet (§7 re-roll). Append-only: the original events
  # stay; this only records that the packet is no longer canonical. Idempotent so
  # a retried re-roll is a no-op, and it refuses to supersede a packet the scene
  # never committed.
  def execute(%__MODULE__{} = state, %SupersedePacket{} = c) do
    cond do
      c.packet_id != nil and MapSet.member?(state.superseded_packets, c.packet_id) ->
        []

      state.status != :open ->
        {:error, :scene_not_open}

      not MapSet.member?(state.committed_packets, c.packet_id) ->
        {:error, :unknown_packet}

      true ->
        %PacketSuperseded{
          scene_id: c.scene_id,
          beat: c.beat,
          character_id: c.character_id,
          packet_id: c.packet_id,
          attempt: c.attempt,
          reason: c.reason
        }
    end
  end

  # Fork (§7): materialize a new scene stream from a rewritten parent prefix. Only
  # valid on a fresh (pending) stream — a fork is a new scene, never a re-open. The
  # prefix events were gathered and re-pointed by `Polyphony.Fork` (rule 1 keeps
  # the cross-stream read out of the aggregate); we emit them verbatim after the
  # `SceneForked` marker so replay rebuilds an ordinary open scene.
  def execute(%__MODULE__{status: :pending}, %ForkScene{} = c) do
    [
      %SceneForked{
        scene_id: c.scene_id,
        parent_scene_id: c.parent_scene_id,
        fork_beat: c.fork_beat,
        label: c.label,
        campaign_id: c.campaign_id
      }
      | c.prefix
    ]
  end

  def execute(%__MODULE__{}, %ForkScene{}), do: {:error, :scene_already_exists}

  # Control mode + turn order (§A1) are declarative facts on the scene log — the
  # beat loop and re-roll read the latest of each. The aggregate just records them
  # (latest-wins is a read-side concern); both require an open scene.
  def execute(%__MODULE__{status: :open} = _s, %SetControlMode{} = c) do
    %ControlModeSet{
      scene_id: c.scene_id,
      character_id: c.character_id,
      control: to_string(c.control)
    }
  end

  def execute(%__MODULE__{}, %SetControlMode{}), do: {:error, :scene_not_open}

  def execute(%__MODULE__{status: :open} = _s, %DeclareTurnOrder{} = c) do
    %TurnOrderDeclared{scene_id: c.scene_id, beat: c.beat, order: Enum.map(c.order, &to_string/1)}
  end

  def execute(%__MODULE__{}, %DeclareTurnOrder{}), do: {:error, :scene_not_open}

  # ── Packet decomposition (§6.4) ───────────────────────────────────────────

  defp decompose(%CommitPacket{} = c) do
    move_events =
      c.packet.moves
      |> Enum.sort_by(& &1.seq)
      |> Enum.map(&move_event(&1, c))

    move_events ++ state_events(c.packet.self_state, c)
  end

  defp move_event(%TurnPacket.Move{type: :thought} = m, c) do
    %ThoughtOccurred{
      character_id: c.character_id,
      scene_id: c.scene_id,
      beat: c.beat,
      packet_id: c.packet_id,
      seq: m.seq,
      content: m.content,
      edited: c.edited
    }
  end

  defp move_event(%TurnPacket.Move{type: :speech} = m, c) do
    %SpeechUttered{
      speaker_id: c.character_id,
      scene_id: c.scene_id,
      beat: c.beat,
      packet_id: c.packet_id,
      seq: m.seq,
      content: m.content,
      addressed_to: m.addressed_to || [],
      audibility: m.audibility || :normal,
      edited: c.edited
    }
  end

  defp move_event(%TurnPacket.Move{type: :action} = m, c) do
    %ActionTaken{
      character_id: c.character_id,
      scene_id: c.scene_id,
      beat: c.beat,
      packet_id: c.packet_id,
      seq: m.seq,
      content: m.content,
      edited: c.edited
    }
  end

  defp state_events(nil, _c), do: []

  defp state_events(%TurnPacket.SelfState{} = s, c) do
    [
      %PrivateStateReported{
        character_id: c.character_id,
        scene_id: c.scene_id,
        beat: c.beat,
        packet_id: c.packet_id,
        mood_felt: s.mood_felt,
        intention: s.intention
      },
      %DemeanorReported{
        character_id: c.character_id,
        scene_id: c.scene_id,
        beat: c.beat,
        packet_id: c.packet_id,
        demeanor: s.demeanor,
        posture: s.posture,
        position: s.position,
        attending_to: s.attending_to
      }
    ]
  end

  # ── State mutators ────────────────────────────────────────────────────────

  def apply(%__MODULE__{} = state, %SceneOpened{} = e) do
    %{
      state
      | scene_id: e.scene_id,
        status: :open,
        campaign_id: e.campaign_id,
        location_id: e.location_id
    }
  end

  def apply(%__MODULE__{} = state, %SceneClosed{}), do: %{state | status: :closed}

  def apply(%__MODULE__{} = state, %CharacterEntered{} = e) do
    %{
      state
      | members: MapSet.put(state.members, e.character_id),
        # Entering resolves any pending proposal for that name.
        pending_introductions: MapSet.delete(state.pending_introductions, norm(e.character_id))
    }
  end

  def apply(%__MODULE__{} = state, %IntroductionProposed{name: n}) do
    %{state | pending_introductions: MapSet.put(state.pending_introductions, norm(n))}
  end

  def apply(%__MODULE__{} = state, %IntroductionDismissed{name: n}) do
    %{state | pending_introductions: MapSet.delete(state.pending_introductions, norm(n))}
  end

  def apply(%__MODULE__{} = state, %CharacterExited{} = e) do
    %{state | members: MapSet.delete(state.members, e.character_id)}
  end

  def apply(%__MODULE__{} = state, %PacketSuperseded{packet_id: id}) when is_binary(id) do
    %{state | superseded_packets: MapSet.put(state.superseded_packets, id)}
  end

  def apply(%__MODULE__{} = state, %SceneForked{parent_scene_id: parent}) do
    %{state | forked_from: parent}
  end

  def apply(%__MODULE__{} = state, %{packet_id: id}) when is_binary(id) do
    %{state | committed_packets: MapSet.put(state.committed_packets, id)}
  end

  def apply(%__MODULE__{} = state, _event), do: state

  # Normalize a character name/id for pending-introduction dedupe (case-insensitive).
  defp norm(name), do: name |> to_string() |> String.trim() |> String.downcase()
end
