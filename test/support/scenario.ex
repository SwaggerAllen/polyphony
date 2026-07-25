defmodule Polyphony.Test.Scenario do
  @moduledoc """
  Hand-written event builders for the pure guarantee tests (§15 slice 1).

  These construct log fragments directly — no aggregate, no runtime — so a test
  can assert that a character's projection excludes what they never witnessed,
  reading almost like the scene it describes.
  """

  alias Polyphony.Events.{
    SceneOpened,
    SceneClosed,
    CharacterEntered,
    CharacterExited,
    ThoughtOccurred,
    PrivateStateReported,
    SpeechUttered,
    ActionTaken,
    DemeanorReported,
    WorldEventOccurred,
    BeatOpened,
    BeatClosed,
    PacketSuperseded,
    GenerationFailed
  }

  def scene_opened(scene, beat, opts \\ []),
    do: %SceneOpened{
      scene_id: scene,
      campaign_id: opts[:campaign_id],
      location_id: opts[:location_id],
      premise: opts[:premise],
      opened_beat: beat
    }

  def scene_closed(scene, beat), do: %SceneClosed{scene_id: scene, closed_beat: beat}

  def entered(scene, char, beat),
    do: %CharacterEntered{scene_id: scene, character_id: char, beat: beat}

  def exited(scene, char, beat),
    do: %CharacterExited{scene_id: scene, character_id: char, beat: beat}

  def thought(char, scene, beat, content, opts \\ []),
    do: %ThoughtOccurred{
      character_id: char,
      scene_id: scene,
      beat: beat,
      content: content,
      packet_id: opts[:packet_id]
    }

  def superseded(scene, char, beat, packet_id, opts \\ []),
    do: %PacketSuperseded{
      scene_id: scene,
      character_id: char,
      beat: beat,
      packet_id: packet_id,
      attempt: opts[:attempt],
      reason: opts[:reason]
    }

  def private_state(char, scene, beat, opts \\ []),
    do: %PrivateStateReported{
      character_id: char,
      scene_id: scene,
      beat: beat,
      mood_felt: opts[:mood_felt],
      intention: opts[:intention]
    }

  def speech(char, scene, beat, content, opts \\ []),
    do: %SpeechUttered{
      speaker_id: char,
      scene_id: scene,
      beat: beat,
      content: content,
      packet_id: opts[:packet_id],
      addressed_to: opts[:addressed_to] || [],
      audibility: opts[:audibility] || :normal
    }

  def action(char, scene, beat, content, opts \\ []),
    do: %ActionTaken{
      character_id: char,
      scene_id: scene,
      beat: beat,
      content: content,
      packet_id: opts[:packet_id]
    }

  def demeanor(char, scene, beat, opts \\ []),
    do: %DemeanorReported{
      character_id: char,
      scene_id: scene,
      beat: beat,
      demeanor: opts[:demeanor],
      posture: opts[:posture],
      position: opts[:position],
      attending_to: opts[:attending_to]
    }

  def world_event(scene, beat, content),
    do: %WorldEventOccurred{scene_id: scene, beat: beat, content: content}

  def beat_opened(beat, cast), do: %BeatOpened{beat: beat, cast: cast}

  def beat_closed(beat, opts \\ []),
    do: %BeatClosed{beat: beat, completed: opts[:completed] || [], failed: opts[:failed] || []}

  def generation_failed(beat, char, reason),
    do: %GenerationFailed{beat: beat, character_id: char, reason: reason}
end
