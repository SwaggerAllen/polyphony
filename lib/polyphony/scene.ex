defmodule Polyphony.Scene do
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

  alias Polyphony.Commands.{OpenScene, CloseScene, EnterCharacter, ExitCharacter, CommitPacket}

  alias Polyphony.Events.{
    SceneOpened,
    SceneClosed,
    CharacterEntered,
    CharacterExited,
    ThoughtOccurred,
    SpeechUttered,
    ActionTaken,
    PrivateStateReported,
    DemeanorReported
  }

  alias Polyphony.TurnPacket

  @type status :: :pending | :open | :closed

  defstruct scene_id: nil,
            status: :pending,
            campaign_id: nil,
            location_id: nil,
            members: MapSet.new(),
            committed_packets: MapSet.new()

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
      content: m.content
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
      audibility: m.audibility || :normal
    }
  end

  defp move_event(%TurnPacket.Move{type: :action} = m, c) do
    %ActionTaken{
      character_id: c.character_id,
      scene_id: c.scene_id,
      beat: c.beat,
      packet_id: c.packet_id,
      seq: m.seq,
      content: m.content
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
    %{state | members: MapSet.put(state.members, e.character_id)}
  end

  def apply(%__MODULE__{} = state, %CharacterExited{} = e) do
    %{state | members: MapSet.delete(state.members, e.character_id)}
  end

  def apply(%__MODULE__{} = state, %{packet_id: id}) when is_binary(id) do
    %{state | committed_packets: MapSet.put(state.committed_packets, id)}
  end

  def apply(%__MODULE__{} = state, _event), do: state
end
