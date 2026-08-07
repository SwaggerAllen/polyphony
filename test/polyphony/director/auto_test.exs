defmodule Polyphony.Director.AutoTest do
  @moduledoc """
  A scene left to run itself, and the three things that stop it.

  Continue advances one beat and hands back — right for playing, useless for the thing
  that needs a *finished* scene: arc review has nothing to review until a scene has run
  long enough to change somebody, and getting there was thirty taps.

  The loop already chains beats. What stopped it every time was the `yield_to_user` hint
  Continue sends and the three-beat depth cap. An auto run drops the hint and raises the
  cap, so the stopping rules a human was standing in for have to become real ones: the
  Director closing the scene, the room emptying, and a hard beat cap.

  Everything here drives the gate rather than the whole Oban chain — the gate is where
  the decision is, and a test that ran fifty real beats would be measuring the provider.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, Repo}
  alias PolyphonyCore.Commands.{CloseScene, EnterCharacter, ExitCharacter, OpenScene}
  alias Polyphony.Director.Auto

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    scene = "auto-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "wren", beat: 1})
    %{scene: scene}
  end

  # The run's own enqueue, captured — what the loop would have been asked to do.
  defp capture(scene, beat \\ 1, opts \\ []) do
    parent = self()
    enqueue = fn args -> send(parent, {:enqueued, args}) end
    Auto.start(scene, beat, [enqueue: enqueue] ++ opts)
  end

  describe "starting" do
    test "claims the scene and asks for the first beat", %{scene: scene} do
      assert {:ok, run} = capture(scene)
      assert run.status == "running"
      assert run.beats_run == 0
      assert run.max_beats == Auto.default_max_beats()

      assert_received {:enqueued, args}
      assert args["scene_id"] == scene
      assert args["beat"] == 1
      # The two that make it an auto beat rather than a Continue: the flag the gate
      # reads, and a hint that isn't `yield_to_user`.
      assert args["auto"] == true
      assert args["control_hint"] == "auto"
    end

    test "a second tap can't put two Directors on the same transcript", %{scene: scene} do
      assert {:ok, _} = capture(scene)
      assert {:error, :taken} = capture(scene)
    end

    test "the cap is what one tap is allowed to spend", %{scene: scene} do
      assert {:ok, run} = capture(scene, 1, max_beats: 4)
      assert run.max_beats == 4
    end
  end

  describe "the gate" do
    test "lets a running scene through", %{scene: scene} do
      {:ok, _} = capture(scene)
      assert Auto.check(scene, 1) == :ok
    end

    test "stops when the Director closes the scene", %{scene: scene} do
      {:ok, _} = capture(scene)
      :ok = App.dispatch(%CloseScene{scene_id: scene, closed_beat: 2})

      # `scene_action: :close` is the only "the story is over" signal the decision
      # contract has, and it lands as `SceneClosed` on the stream.
      assert Auto.check(scene, 2) == {:stop, :closed}
    end

    test "stops when the room empties", %{scene: scene} do
      {:ok, _} = capture(scene)
      :ok = App.dispatch(%ExitCharacter{scene_id: scene, character_id: "wren", beat: 2})

      # A Director casting from an empty roster writes nothing, forever. A `:move`
      # scene action lands here too — it exits the character it moves.
      assert Auto.check(scene, 2) == {:stop, :empty}
    end

    test "stops at the beat cap", %{scene: scene} do
      {:ok, _} = capture(scene, 1, max_beats: 2)
      Auto.note_beat(scene, 1)
      assert Auto.check(scene, 2) == :ok

      Auto.note_beat(scene, 2)
      assert Auto.check(scene, 3) == {:stop, :cap}
    end

    test "a scene nobody started is stopped without an ending", %{scene: scene} do
      # Not an ending — nothing to announce and nothing to write down. The distinction
      # matters: `{:stop, nil}` must not stamp an `ended_reason` on a run that isn't
      # there, or a paused scene comes back saying it finished.
      assert Auto.check(scene, 1) == {:stop, nil}
    end
  end

  describe "pause and resume" do
    test "pausing stops the gate letting anything else through", %{scene: scene} do
      {:ok, _} = capture(scene)
      assert {:ok, run} = Auto.pause(scene)
      assert run.status == "paused"

      assert Auto.check(scene, 2) == {:stop, nil}
    end

    test "resuming asks for the beat it is on now, not the one it started at",
         %{scene: scene} do
      {:ok, _} = capture(scene)
      assert_received {:enqueued, _first}
      Auto.note_beat(scene, 1)
      Auto.note_beat(scene, 2)
      {:ok, _} = Auto.pause(scene)

      parent = self()
      {:ok, run} = Auto.resume(scene, 7, enqueue: fn args -> send(parent, {:enqueued, args}) end)

      assert run.status == "running"
      assert_received {:enqueued, args}
      assert args["beat"] == 7
      assert args["auto"] == true
      # And with what's left of the budget, not a fresh fifty.
      assert args["max_depth"] == run.max_beats - 2
    end

    test "the count survives the pause, so a resume can't quietly buy more beats",
         %{scene: scene} do
      {:ok, _} = capture(scene, 1, max_beats: 3)
      Auto.note_beat(scene, 1)
      Auto.note_beat(scene, 2)
      {:ok, _} = Auto.pause(scene)
      {:ok, _} = Auto.resume(scene, 3, enqueue: fn _ -> :ok end)

      assert %{beats_run: 2, max_beats: 3} = Auto.get(scene)
      Auto.note_beat(scene, 3)
      assert Auto.check(scene, 4) == {:stop, :cap}
    end

    test "pausing what isn't running, and resuming what isn't paused", %{scene: scene} do
      assert {:error, :not_running} = Auto.pause(scene)
      assert {:error, :not_paused} = Auto.resume(scene, 1, enqueue: fn _ -> :ok end)
    end

    test "a finished run can be started again from scratch", %{scene: scene} do
      {:ok, _} = capture(scene, 1, max_beats: 2)
      Auto.note_beat(scene, 1)
      Auto.finish(scene, :cap)

      assert %{status: "done", ended_reason: "Reached the beat limit."} = Auto.get(scene)

      # "Run this scene for fifty beats" is what the button says; carrying the old count
      # over would silently make it fewer.
      assert {:ok, run} = capture(scene, 2, max_beats: 2)
      assert run.beats_run == 0
      assert run.ended_reason == nil
    end
  end

  describe "finishing" do
    test "writes down which of the three ends it was", %{scene: scene} do
      for {reason, text} <- [
            {:closed, "The Director closed the scene."},
            {:empty, "Everyone has left."},
            {:cap, "Reached the beat limit."}
          ] do
        {:ok, _} = capture(scene)
        Auto.finish(scene, reason)
        assert %{status: "done", ended_reason: ^text} = Auto.get(scene)
      end
    end

    test "and tells whoever is watching", %{scene: scene} do
      Auto.subscribe(scene)
      {:ok, _} = capture(scene)

      assert_receive {:scene_auto, %{status: "running"}}

      Auto.finish(scene, :empty)
      assert_receive {:scene_auto, %{status: "done", ended_reason: "Everyone has left."}}
    end
  end
end
