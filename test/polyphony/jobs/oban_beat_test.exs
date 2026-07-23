defmodule Polyphony.Jobs.ObanBeatTest do
  @moduledoc """
  The Oban-driven beat loop (RunBeat → chained GeneratePacket → CloseBeat →
  RunBeat) run end-to-end in Oban's `:inline` testing mode with the Mock
  provider. Serial ordering falls out of the enqueue-next-on-completion chain;
  no network, no live queue.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Context, MembershipSet, Visibility}
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Jobs.RunBeat
  alias Polyphony.Events.{ThoughtOccurred, SpeechUttered, BeatClosed}

  @mock "Elixir.Polyphony.LLM.Mock"

  defp stored(stream),
    do: App |> Commanded.EventStore.stream_forward(stream) |> Enum.map(& &1.data)

  defp setup_scene(members) do
    scene = "obl-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for m <- members do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})

      sheet = %CharacterSheet{name: m, premise: "#{m} is present.", voice: "plain"}

      ctx =
        Context.materialize(scene_id: scene, character_id: m, sheet: sheet, premise: "A hall.")

      Store.put(scene, m, ctx)
    end

    scene
  end

  test "a single beat runs the cast serially through the job chain and closes" do
    scene = setup_scene(["mira", "otto"])

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => @mock,
        "control_hint" => "yield_to_user"
      })
    end)

    events = stored(scene)
    assert Enum.count(events, &match?(%ThoughtOccurred{}, &1)) == 2
    assert Enum.count(events, &match?(%SpeechUttered{}, &1)) == 2

    assert %BeatClosed{completed: ["mira", "otto"], failed: []} =
             Enum.find(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))
  end

  test "the guarantee holds over Oban-committed packets" do
    scene = setup_scene(["mira", "otto"])

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{"scene_id" => scene, "beat" => 2, "provider" => @mock})
    end)

    events = stored(scene)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    otto_view = Visibility.project(events, {:character, "otto"}, member_at?)

    assert Enum.any?(otto_view, &match?(%SpeechUttered{speaker_id: "mira"}, &1))
    refute Enum.any?(otto_view, &match?(%ThoughtOccurred{character_id: "mira"}, &1))
  end

  test "the chain re-enqueues RunBeat and loops to the depth cap" do
    scene = setup_scene(["mira"])

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 1,
        "provider" => @mock,
        "control_hint" => "continue",
        "max_depth" => 2
      })
    end)

    # Two beats (depth 0 continues, depth 1 hits the cap): one packet each.
    assert Enum.count(stored(scene), &match?(%ThoughtOccurred{}, &1)) == 2
    assert match?(%BeatClosed{}, Enum.find(stored("#{scene}-b1"), &match?(%BeatClosed{}, &1)))
    assert match?(%BeatClosed{}, Enum.find(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1)))
  end
end
