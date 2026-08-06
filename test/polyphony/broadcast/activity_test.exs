defmodule Polyphony.Broadcast.ActivityTest do
  @moduledoc """
  The beat loop's activity cache, and the ways it is allowed to be wrong.

  It exists so a viewer arriving mid-beat sees the placeholder — `announce_progress/3`
  is a broadcast, and a broadcast is only ever seen by whoever was already listening.
  Everything here is about the *edges*: what it refuses to remember, and that every way
  it can fail lands on "idle" rather than on a scene wedged behind a spinner nobody can
  clear.
  """
  use ExUnit.Case, async: false

  alias Polyphony.Broadcast
  alias Polyphony.Broadcast.Activity

  setup do
    scene = "act-" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Activity.put(scene, :idle) end)
    %{scene: scene}
  end

  test "a busy phase is remembered, with who and which beat", %{scene: scene} do
    Activity.put(scene, :generating, subject: "c-1", beat: 4)

    assert %{phase: :generating, subject: "c-1", beat: 4} = Activity.get(scene)
  end

  test "idle clears it rather than storing an idle row", %{scene: scene} do
    Activity.put(scene, :director, beat: 1)
    Activity.put(scene, :idle, beat: 1)

    assert Activity.get(scene) == nil
  end

  test "so does a pause on the author", %{scene: scene} do
    Activity.put(scene, :generating, subject: "c-1", beat: 1)
    Activity.put(scene, :awaiting_user, subject: "c-1", beat: 1)

    # Not a spinner: `PlayLive.take_turn/3` routes a turn into the slot this names, at
    # this beat. A restored stale one commits into a closed beat.
    assert Activity.get(scene) == nil
  end

  test "an unknown scene is idle, not a crash", %{scene: scene} do
    assert Activity.get(scene <> "-nope") == nil
    assert Broadcast.progress(scene <> "-nope") == %{phase: :idle, subject: nil, beat: nil}
  end

  test "announcing goes through it, so the two can't drift", %{scene: scene} do
    Broadcast.announce_progress(scene, :director, beat: 2)
    assert %{phase: :director, beat: 2} = Broadcast.progress(scene)

    Broadcast.announce_progress(scene, :idle, beat: 2)
    assert %{phase: :idle} = Broadcast.progress(scene)
  end

  test "ids are compared as strings, so an integer scene id round-trips", %{scene: _} do
    id = System.unique_integer([:positive])
    Activity.put(id, :director, beat: 1)

    assert %{phase: :director} = Activity.get(to_string(id))
    Activity.put(id, :idle)
  end

  test "a stale row reads as idle, so a dead job can't wedge the screen", %{scene: scene} do
    # Written directly with an old timestamp: the failure this guards is a job that dies
    # without announcing anything, and there is no way to provoke that in a unit test
    # without either sleeping five minutes or reaching into the table.
    :ets.insert(
      Activity,
      {scene, :director, nil, 1, System.monotonic_time(:millisecond) - :timer.minutes(6)}
    )

    assert Activity.get(scene) == nil
  end

  test "a row that is merely old-ish is still live", %{scene: scene} do
    # A heavy-model retry after a 60s call is a real beat, not a stuck one.
    :ets.insert(
      Activity,
      {scene, :director, nil, 1, System.monotonic_time(:millisecond) - :timer.minutes(2)}
    )

    assert %{phase: :director} = Activity.get(scene)
  end
end
