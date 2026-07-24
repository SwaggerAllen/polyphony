defmodule Polyphony.TurnOrderTest do
  @moduledoc """
  §A1: explicit, user-settable turn order + control modes, and multiple yields per
  beat. The Director's cast is a default the user can reorder, remove from, or drive
  a slot of themselves — and the beat loop walks it, yielding on user-controlled
  slots and resuming on the user's packet.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Context, TurnOrder, Packets, Reroll}
  alias Polyphony.LLM.Mock
  alias Polyphony.Director.{Runner, Beat}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter, SetControlMode, DeclareTurnOrder}
  alias Polyphony.Director.Commands.{OpenBeat, RecordPacket, RecordPass}
  alias Polyphony.Events.{ThoughtOccurred, ControlModeSet, TurnOrderDeclared}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}

  defp stored(s), do: App |> Commanded.EventStore.stream_forward(s) |> Enum.map(& &1.data)
  defp canonical(s), do: s |> stored() |> Packets.canonical()

  defp thought_chars(s),
    do: for(%ThoughtOccurred{character_id: c} <- canonical(s), do: c) |> Enum.uniq()

  defp setup_scene(members) do
    scene = "a1-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    for m <- members, do: App.dispatch(%EnterCharacter{scene_id: scene, character_id: m, beat: 1})

    contexts =
      Map.new(members, fn m ->
        sheet = %CharacterSheet{name: m, premise: "#{m} is here.", voice: "plain"}

        {m,
         Context.materialize(scene_id: scene, character_id: m, sheet: sheet, premise: "A room.")}
      end)

    {scene, contexts}
  end

  defp user_packet(mark) do
    %TurnPacket{
      moves: [
        %Move{seq: 1, type: :thought, content: "#{mark}-thought"},
        %Move{seq: 2, type: :speech, content: "#{mark}-speech"}
      ],
      self_state: %SelfState{}
    }
  end

  describe "reading the declarative facts (latest-wins)" do
    test "control mode defaults to autonomous and takes the latest set" do
      events = [
        %ControlModeSet{scene_id: "S", character_id: "a", control: "user_controlled"},
        %ControlModeSet{scene_id: "S", character_id: "a", control: "autonomous"}
      ]

      assert TurnOrder.control_mode(events, "a") == "autonomous"
      assert TurnOrder.control_mode(events, "unknown") == "autonomous"
      refute TurnOrder.user_controlled?(events, "a")
    end

    test "turn order is the latest declaration for the beat" do
      events = [
        %TurnOrderDeclared{scene_id: "S", beat: 2, order: ["a", "b", "c"]},
        %TurnOrderDeclared{scene_id: "S", beat: 2, order: ["b", "a"]}
      ]

      assert TurnOrder.for_beat(events, 2) == ["b", "a"]
      assert TurnOrder.for_beat(events, 9) == nil
    end
  end

  test "a user-controlled slot yields mid-beat; resume walks the rest" do
    {scene, contexts} = setup_scene(["alice", "bram", "cara"])

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "bram",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    assert {:awaiting_user, %{character_id: "bram", beat: 2}} =
             Runner.run_beat(%{scene_id: scene, beat: 2, contexts: contexts, provider: Mock})

    # Alice (autonomous, before the yield) generated; bram/cara have not.
    assert thought_chars(scene) == ["alice"]

    # The user writes bram's turn → resume generates cara → the beat closes.
    assert {:ok, %{committed: committed}} =
             Runner.submit_user_turn(scene, 2, "bram", user_packet("bram"), %{
               contexts: contexts,
               provider: Mock
             })

    assert "bram" in committed and "cara" in committed
    assert Enum.sort(thought_chars(scene)) == ["alice", "bram", "cara"]
  end

  test "two user-controlled slots yield twice; a pass lets the beat settle" do
    {scene, contexts} = setup_scene(["alice", "bram", "cara"])

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "alice",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "cara",
        control: "user_controlled"
      })

    :ok =
      App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram", "cara"]})

    opts = %{contexts: contexts, provider: Mock}

    # First slot is user-controlled → immediate yield, nothing generated.
    assert {:awaiting_user, %{character_id: "alice"}} =
             Runner.run_beat(%{scene_id: scene, beat: 2, contexts: contexts, provider: Mock})

    assert thought_chars(scene) == []

    # User writes alice → bram (autonomous) generates → yields again for cara.
    assert {:awaiting_user, %{character_id: "cara"}} =
             Runner.submit_user_turn(scene, 2, "alice", user_packet("alice"), opts)

    assert Enum.sort(thought_chars(scene)) == ["alice", "bram"]

    # User skips cara → the beat settles and closes.
    assert {:ok, %{passed: passed}} = Runner.pass_turn(scene, 2, "cara", opts)
    assert "cara" in passed
  end

  test "declaring an order that omits a character removes them from the beat" do
    {scene, contexts} = setup_scene(["alice", "bram", "cara"])
    # The user drops bram from this beat.
    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "cara"]})

    assert {:ok, _} =
             Runner.run_beat(%{scene_id: scene, beat: 2, contexts: contexts, provider: Mock})

    assert Enum.sort(thought_chars(scene)) == ["alice", "cara"]
    refute "bram" in thought_chars(scene)
  end

  test "re-roll supersedes a user turn in the tail but never regenerates it" do
    {scene, contexts} = setup_scene(["alice", "bram"])

    :ok =
      App.dispatch(%SetControlMode{
        scene_id: scene,
        character_id: "bram",
        control: "user_controlled"
      })

    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 2, order: ["alice", "bram"]})

    opts = %{contexts: contexts, provider: Mock}

    {:awaiting_user, _} =
      Runner.run_beat(%{scene_id: scene, beat: 2, contexts: contexts, provider: Mock})

    {:ok, _} = Runner.submit_user_turn(scene, 2, "bram", user_packet("bram-orig"), opts)

    # Re-rolling alice puts bram (user-controlled) in the tail.
    assert {:ok, %{results: results}} = Reroll.reroll(scene, 2, "alice", provider: Mock)
    assert {"bram", :awaiting_user} in results

    # Bram's turn is superseded (it conditioned on the change) but not clobbered by
    # a generated one — it's the user's to re-write.
    refute Enum.any?(
             canonical(scene),
             &match?(%ThoughtOccurred{content: "bram-orig-thought"}, &1)
           )

    assert for(%ThoughtOccurred{character_id: "bram"} <- canonical(scene), do: 1) == []
  end

  test "the beat aggregate counts a pass as terminal so a yielded beat can settle" do
    s0 = %Beat{}

    opened =
      Beat.apply(
        s0,
        Beat.execute(s0, %OpenBeat{beat_ref: "b", scene_id: "S", beat: 2, cast: ["a", "b"]})
      )

    refute Beat.settled?(opened)

    s1 = Beat.apply(opened, Beat.execute(opened, %RecordPacket{beat_ref: "b", character_id: "a"}))
    refute Beat.settled?(s1)

    s2 = Beat.apply(s1, Beat.execute(s1, %RecordPass{beat_ref: "b", character_id: "b"}))
    assert Beat.settled?(s2)
  end
end
