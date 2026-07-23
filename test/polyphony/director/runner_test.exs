defmodule Polyphony.Director.RunnerTest do
  @moduledoc """
  The beat runner end-to-end (§10) with the lorem-ipsum Mock provider — no
  network. Exercises the serial cast chain, the beat lifecycle, truncation on
  membership change, and the depth-capped loop.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Context, MembershipSet, Visibility}
  alias Polyphony.LLM.Mock
  alias Polyphony.Director.{Runner, Options, Proposal}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  alias Polyphony.Events.{
    ThoughtOccurred,
    SpeechUttered,
    BeatClosed,
    CharacterExited,
    WorldEventOccurred
  }

  defp stored(scene), do: App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)

  defp setup_scene(members) do
    scene = "run-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for m <- members do
      :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})
    end

    contexts =
      Map.new(members, fn m ->
        sheet = %CharacterSheet{name: m, premise: "#{m} is here.", voice: "plain"}

        {m,
         Context.materialize(scene_id: scene, character_id: m, sheet: sheet, premise: "A room.")}
      end)

    {scene, contexts}
  end

  test "a beat casts the members, generates them serially, and closes with the split" do
    {scene, contexts} = setup_scene(["mira", "otto"])

    assert {:ok, outcome} =
             Runner.run_beat(%{
               scene_id: scene,
               beat: 2,
               contexts: contexts,
               provider: Mock,
               control_hint: :yield_to_user
             })

    assert outcome.committed == ["mira", "otto"]
    assert outcome.next == :yield_to_user

    events = stored(scene)
    assert Enum.count(events, &match?(%ThoughtOccurred{}, &1)) == 2
    assert Enum.count(events, &match?(%SpeechUttered{}, &1)) == 2

    # The beat lifecycle lives on its own aggregate stream. It closed cleanly
    # with both committed and none failed (§12).
    assert %BeatClosed{completed: ["mira", "otto"], failed: []} =
             Enum.find(stored("#{scene}-b2"), &match?(%BeatClosed{}, &1))
  end

  test "the guarantee still holds over runner-generated packets" do
    {scene, contexts} = setup_scene(["mira", "otto"])
    {:ok, _} = Runner.run_beat(%{scene_id: scene, beat: 2, contexts: contexts, provider: Mock})

    events = stored(scene)
    member_at? = events |> MembershipSet.from_events() |> MembershipSet.member_at_fun()

    otto_view = Visibility.project(events, {:character, "otto"}, member_at?)
    # Otto sees Mira's speech but never her thought, even though the runner made
    # both in the same beat.
    assert Enum.any?(otto_view, &match?(%SpeechUttered{speaker_id: "mira"}, &1))
    refute Enum.any?(otto_view, &match?(%ThoughtOccurred{character_id: "mira"}, &1))
  end

  test "an accepted exit truncates the beat: no cast generates, and re-decide follows" do
    {scene, contexts} = setup_scene(["mira", "otto"])

    exit_proposal = %Proposal{actor_id: "mira", type: :exit, target: "gate"}

    assert {:ok, outcome} =
             Runner.run_beat(%{
               scene_id: scene,
               beat: 2,
               contexts: contexts,
               provider: Mock,
               proposals: [exit_proposal],
               options: Options.for_scene([%{label: "gate"}], [])
             })

    assert outcome.membership_changed
    assert outcome.next == :truncate
    assert outcome.committed == []

    events = stored(scene)
    assert Enum.any?(events, &match?(%CharacterExited{character_id: "mira"}, &1))
    # No packets were generated this beat.
    refute Enum.any?(events, &match?(%ThoughtOccurred{beat: 2}, &1))
  end

  test "rejected proposals surface as in-fiction world events" do
    {scene, contexts} = setup_scene(["mira"])

    bogus = %Proposal{actor_id: "mira", type: :exit, target: "chimney"}

    {:ok, _} =
      Runner.run_beat(%{
        scene_id: scene,
        beat: 2,
        contexts: contexts,
        provider: Mock,
        proposals: [bogus],
        options: Options.for_scene([%{label: "gate"}], [])
      })

    assert Enum.any?(stored(scene), fn e ->
             match?(%WorldEventOccurred{}, e) and e.content =~ "chimney"
           end)
  end

  test "the loop runs until the depth cap and then yields" do
    {scene, contexts} = setup_scene(["mira"])

    assert {:ok, outcomes} =
             Runner.run(%{
               scene_id: scene,
               contexts: contexts,
               provider: Mock,
               control_hint: :continue,
               max_depth: 3
             })

    # continue, continue, then forced yield at the cap → 3 beats.
    assert length(outcomes) == 3
    assert List.last(outcomes).next == :yield_to_user
  end
end
