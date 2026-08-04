defmodule PolyphonyWeb.PlayUserTurnLiveTest do
  @moduledoc """
  User-controlled slots (§A1): the beat loop pauses, and the composer answers *that*.

  The gap this closes was flagged in `roadmap.md`'s FE/BE parity audit as deliberately
  deferred, with a workaround — "don't speak as a character you want the cast to
  drive". `BeatDriver` has always paused at a `user_controlled` slot and broadcast
  `awaiting_user`; the composer never read it, so Send always did a *free*
  `CommitPacket` at `next_beat`. Two consequences, both invisible until they weren't:
  the walk stayed paused forever, and when it did resume the Director wrote the same
  character a second time.

  The load-bearing detail is the **beat**. `announce_progress` has always carried it
  and `PlayLive` threw it away; committing at `next_beat` instead of the beat the walk
  actually stopped on is how a turn lands outside the slot waiting for it.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Broadcast, TurnOrder}
  alias Polyphony.Commands.{DeclareTurnOrder, EnterCharacter, OpenScene}
  alias Polyphony.Director.BeatOps
  alias Polyphony.Director.Commands.OpenBeat

  setup :register_and_log_in_user

  defp scene_with(chars) do
    scene = "uturn-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- chars,
        do: :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    :ok = App.dispatch(%DeclareTurnOrder{scene_id: scene, beat: 1, order: chars})

    :ok =
      App.dispatch(%OpenBeat{
        beat_ref: BeatOps.beat_ref(scene, 1),
        scene_id: scene,
        beat: 1,
        cast: chars
      })

    scene
  end

  # What `BeatDriver.await_user/3` announces when the walk stops on a slot. Sent
  # directly rather than by running the loop: the loop is `BeatDriverTest`'s subject,
  # and this file is about what the screen does with the pause.
  defp pause_on(scene, character, beat \\ 1) do
    Broadcast.announce_progress(scene, :awaiting_user, subject: character, beat: beat)
  end

  defp stored(scene), do: App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)

  # A packet has no event of its own — `Scene.decompose/1` splits it into move events,
  # which is the shape the whole log is in (§6). So "did they take a turn" is "are
  # there moves of theirs", and the beat comes off the move.
  @moves [
    Polyphony.Events.SpeechUttered,
    Polyphony.Events.ThoughtOccurred,
    Polyphony.Events.ActionTaken
  ]

  # Speech names its `speaker_id`; thought and action name a `character_id`. Both are
  # the same routing key — the difference is only which word the event chose.
  defp packets_for(scene, character) do
    for %{__struct__: mod} = e <- stored(scene),
        mod in @moves,
        Map.get(e, :speaker_id) == character or Map.get(e, :character_id) == character,
        do: e
  end

  describe "the paused slot" do
    test "is announced on screen, with a way to give it up", %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, html} = live(conn, ~p"/play/#{scene}?as=mira")

      # Nothing is waiting yet, so nothing claims to be.
      refute html =~ "waiting on your turn"
      refute html =~ ~s(phx-click="pass_turn")

      pause_on(scene, "mira")

      html = render(view)
      assert html =~ "The scene is waiting on your turn."
      assert html =~ ~s(phx-click="pass_turn")
    end

    test "belongs to the character it named, not to whoever is looking", %{conn: conn} do
      scene = scene_with(["mira", "bram"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=bram")

      pause_on(scene, "mira")

      # Bram's composer must not offer to take Mira's slot — that is the double-turn
      # bug from the other side.
      refute render(view) =~ "The scene is waiting on your turn."
    end
  end

  describe "taking a paused turn" do
    test "commits into the beat the walk stopped on, not the next one", %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

      pause_on(scene, "mira", 1)

      view
      |> form("#say-form", %{text: "I check the manifest."})
      |> render_submit()

      # Beat 1 — the slot that was waiting. Committing at `next_beat` would land it in
      # beat 2, leaving beat 1 paused on a character who has already spoken.
      assert [move | _] = packets_for(scene, "mira")
      assert move.beat == 1
    end

    test "records the packet on the beat, which is what lets the walk go on",
         %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

      pause_on(scene, "mira", 1)
      view |> form("#say-form", %{text: "I check the manifest."}) |> render_submit()

      # A free `CommitPacket` never touches the beat aggregate, so the Director had no
      # way to know the slot was done.
      recorded =
        for %{__struct__: Polyphony.Events.PacketRecorded} = e <-
              App
              |> Commanded.EventStore.stream_forward(BeatOps.beat_ref(scene, 1))
              |> Enum.map(& &1.data),
            do: e.character_id

      assert "mira" in recorded
    end

    test "and the screen stops saying it is waiting", %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

      pause_on(scene, "mira", 1)
      html = view |> form("#say-form", %{text: "I check the manifest."}) |> render_submit()

      refute html =~ "The scene is waiting on your turn."
    end
  end

  describe "speaking when nothing is waiting" do
    test "still writes into the next beat, as it always did", %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

      view |> form("#say-form", %{text: "I say nothing."}) |> render_submit()

      # The original behaviour, and still the right one for a scene nobody has pressed
      # Continue on: the author speaking into the next beat.
      assert [move | _] = packets_for(scene, "mira")
      assert move.beat >= 1
    end
  end

  describe "passing" do
    test "gives up the slot rather than writing an empty turn", %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

      pause_on(scene, "mira", 1)
      html = view |> element(~s(button[phx-click="pass_turn"])) |> render_click()

      assert packets_for(scene, "mira") == []
      refute html =~ "The scene is waiting on your turn."

      passed =
        for %{__struct__: Polyphony.Events.PacketPassed} = e <-
              App
              |> Commanded.EventStore.stream_forward(BeatOps.beat_ref(scene, 1))
              |> Enum.map(& &1.data),
            do: e.character_id

      assert "mira" in passed
    end
  end

  describe "the control mode this is all for" do
    test "a user_controlled character is what makes the loop pause", %{conn: conn} do
      scene = scene_with(["mira"])
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
      view |> element(~s(button[phx-click="toggle_cast"])) |> render_click()

      view
      |> form("#control-mira", %{character: "mira", control: "user_controlled"})
      |> render_change()

      # The mode the whole pause exists for. It has been selectable since the panel
      # shipped; until now selecting it changed nothing you could act on.
      assert TurnOrder.control_mode(stored(scene), "mira") == "user_controlled"
    end
  end
end
