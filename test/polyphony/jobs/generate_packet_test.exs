defmodule Polyphony.Jobs.GeneratePacketTest do
  @moduledoc """
  Slice 3 end-to-end: an Oban job runs a (stubbed) generation and dispatches a
  CommitPacket, whose decomposed events land in the store and obey the visibility
  guarantee. No LLM, no network — the stub provider stands in for DeepInfra.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Polyphony.Repo

  alias Polyphony.{App, MembershipSet, Visibility}
  alias Polyphony.Jobs.GeneratePacket
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Events.{ThoughtOccurred, SpeechUttered}
  alias Polyphony.LLM.Stub

  defp stored_events(scene_id) do
    App |> Commanded.EventStore.stream_forward(scene_id) |> Enum.map(& &1.data)
  end

  defp open_scene_with(scene, chars) do
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- chars do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})
    end
  end

  test "a generation job commits a packet whose events obey the projection" do
    scene = "job-scene-" <> Integer.to_string(System.unique_integer([:positive]))
    open_scene_with(scene, ["mira", "otto"])

    args = %{
      "scene_id" => scene,
      "character_id" => "mira",
      "beat" => 2,
      "packet_id" => scene <> "-2-mira"
    }

    assert :ok = perform_job(GeneratePacket, args)

    events = stored_events(scene)

    # The canned packet contains a thought and a speech line; both were committed.
    assert Enum.any?(events, &match?(%ThoughtOccurred{character_id: "mira"}, &1))
    assert Enum.any?(events, &match?(%SpeechUttered{speaker_id: "mira"}, &1))

    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()

    # Otto hears Mira's line but not her interior thought — the guarantee holds
    # over a for-real generated-and-committed packet.
    otto_view = Visibility.project(events, {:character, "otto"}, member_at?)
    assert Enum.any?(otto_view, &match?(%SpeechUttered{speaker_id: "mira"}, &1))
    refute Enum.any?(otto_view, &match?(%ThoughtOccurred{}, &1))
  end

  test "a duplicate job (same packet_id) commits exactly once (§12 idempotency)" do
    scene = "job-scene-" <> Integer.to_string(System.unique_integer([:positive]))
    open_scene_with(scene, ["mira"])

    args = %{
      "scene_id" => scene,
      "character_id" => "mira",
      "beat" => 2,
      "packet_id" => scene <> "-2-mira"
    }

    assert :ok = perform_job(GeneratePacket, args)
    assert :ok = perform_job(GeneratePacket, args)

    thoughts = scene |> stored_events() |> Enum.count(&match?(%ThoughtOccurred{}, &1))

    assert thoughts == 1, "the packet must be committed exactly once"
  end

  test "a persistent refusal cancels the job rather than looping (§12)" do
    prev = Application.get_env(:polyphony, :llm)

    Application.put_env(
      :polyphony,
      :llm,
      Keyword.put(prev, :stub_response, {:ok, Stub.refusal_text()})
    )

    on_exit(fn -> Application.put_env(:polyphony, :llm, prev) end)

    scene = "job-scene-" <> Integer.to_string(System.unique_integer([:positive]))
    open_scene_with(scene, ["mira"])

    args = %{
      "scene_id" => scene,
      "character_id" => "mira",
      "beat" => 2,
      "packet_id" => scene <> "-2-mira"
    }

    # Refuses on the workhorse, swaps to the heavy model, still refuses → cancel.
    assert {:cancel, {:refusal, _}} = perform_job(GeneratePacket, args)

    # Nothing was committed for the beat.
    refute Enum.any?(stored_events(scene), &match?(%ThoughtOccurred{}, &1))
  end
end
