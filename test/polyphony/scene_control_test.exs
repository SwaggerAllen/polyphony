defmodule Polyphony.SceneControlTest do
  @moduledoc """
  §B7: manual scene control + Continue. Add/remove emit membership events directly
  (author lever), effective at the given beat boundary; a stub is refused until
  promoted; Continue kicks a beat run with no user packet.
  """
  use ExUnit.Case, async: false

  alias Polyphony.{App, SceneControl}
  alias Polyphony.Core.MembershipSet
  alias Polyphony.Commands.OpenScene
  alias Polyphony.Events.{CharacterEntered, CharacterExited}

  defp stored(scene), do: App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)

  defp open_scene do
    scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    scene
  end

  test "add_character emits CharacterEntered; membership holds from that beat" do
    scene = open_scene()
    assert :ok = SceneControl.add_character(scene, "mira", 1)

    assert Enum.any?(stored(scene), &match?(%CharacterEntered{character_id: "mira", beat: 1}, &1))

    member_at? = scene |> stored() |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    assert member_at?.(scene, "mira", 1)
    refute member_at?.(scene, "mira", 0)
  end

  test "remove_character emits CharacterExited; membership ends at that beat (half-open)" do
    scene = open_scene()
    :ok = SceneControl.add_character(scene, "mira", 1)
    :ok = SceneControl.remove_character(scene, "mira", 3)

    assert Enum.any?(stored(scene), &match?(%CharacterExited{character_id: "mira", beat: 3}, &1))

    member_at? = scene |> stored() |> MembershipSet.from_events() |> MembershipSet.member_at_fun()
    assert member_at?.(scene, "mira", 2)
    # [entered, exited): exited at 3 means not a member at 3.
    refute member_at?.(scene, "mira", 3)
  end

  test "adding a stub is refused until promotion (§B8)" do
    scene = open_scene()

    assert {:error, :stub_needs_promotion} =
             SceneControl.add_character(scene, "ghost", 1, status: :stub)

    refute Enum.any?(stored(scene), &match?(%CharacterEntered{character_id: "ghost"}, &1))
  end

  test "continue enqueues a beat run with an empty user turn" do
    scene = open_scene()
    parent = self()
    enqueue = fn args -> send(parent, {:enqueued, args}) end

    SceneControl.continue(scene, 2, enqueue: enqueue)

    assert_received {:enqueued, args}
    assert args["scene_id"] == scene
    assert args["beat"] == 2
    assert args["continue"] == true
  end
end
