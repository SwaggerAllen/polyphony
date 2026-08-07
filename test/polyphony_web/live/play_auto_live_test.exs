defmodule PolyphonyWeb.PlayAutoLiveTest do
  @moduledoc """
  The Auto control on the play screen, and the loop actually running itself.

  The end-to-end test here is the one worth having: it starts a run, drains the queues,
  and asserts the transcript grew by more than one beat without anybody pressing
  anything. Continue's whole job is to stop after one, so "more than one" is the entire
  claim — and it is the claim that breaks if the `yield_to_user` hint, the depth cap, or
  the `auto` flag stops riding the chain.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.Commands.{EnterCharacter, ExitCharacter, OpenScene}
  alias Polyphony.Director.{Auto, BeatOps}
  alias PolyphonyCore.Events.SpeechUttered

  setup :register_and_log_in_user

  setup do
    # The run keeps broadcasting after the test body ends, and a still-mounted view
    # reloads on each one — against a sandbox connection that has gone.
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp scene(user) do
    wren =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full, premise: "She counts twice."}
      })

    id = "pauto-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: id, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(wren.id), beat: 1})
    %{scene: id, wren: wren}
  end

  defp drain do
    for _ <- 1..8 do
      Oban.drain_queue(queue: :director, with_recursion: true, with_scheduled: true)
      Oban.drain_queue(queue: :generation, with_recursion: true, with_scheduled: true)
    end
  end

  defp speeches(scene),
    do: scene |> BeatOps.stored_events() |> Enum.count(&match?(%SpeechUttered{}, &1))

  describe "the control" do
    test "offers Auto, and swaps to Pause once it is running", %{conn: conn, user: user} do
      %{scene: scene} = scene(user)

      {:ok, view, html} = live(conn, ~p"/play/#{scene}")
      assert html =~ ~s(phx-click="start_auto")
      refute html =~ ~s(phx-click="pause_auto")

      running = view |> element("button[phx-click=start_auto]") |> render_click()

      # One control, one verb. A bar carrying Auto, Pause and Resume at once asks the
      # author which of three things is currently true.
      assert running =~ ~s(phx-click="pause_auto")
      refute running =~ ~s(phx-click="start_auto")
      assert running =~ "Running itself — beat 0 of 50"
    end

    test "pause and resume, and the count is kept across both",
         %{conn: conn, user: user} do
      %{scene: scene} = scene(user)
      {:ok, view, _} = live(conn, ~p"/play/#{scene}")

      view |> element("button[phx-click=start_auto]") |> render_click()
      Auto.note_beat(scene, 1)

      paused = view |> element("button[phx-click=pause_auto]") |> render_click()
      assert paused =~ "Paused at beat 1 of 50"
      assert paused =~ ~s(phx-click="resume_auto")

      resumed = view |> element("button[phx-click=resume_auto]") |> render_click()
      assert resumed =~ "Running itself — beat 1 of 50"
    end

    test "a second tap says so instead of starting a second loop",
         %{conn: conn, user: user} do
      %{scene: scene} = scene(user)
      {:ok, _} = Auto.start(scene, 1, enqueue: fn _ -> :ok end)

      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      # The screen shows Pause, so reach for the event directly — the guard is the
      # context's, and a second tab is exactly where it earns its keep.
      assert render_click(view, "start_auto", %{}) =~ "already running itself"
    end

    test "the state is on the screen after a reload, not only in the tab that started it",
         %{conn: conn, user: user} do
      %{scene: scene} = scene(user)
      {:ok, _} = Auto.start(scene, 1, enqueue: fn _ -> :ok end)
      Auto.note_beat(scene, 1)
      Auto.note_beat(scene, 2)

      {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ "Running itself — beat 2 of 50"
      assert html =~ ~s(phx-click="pause_auto")
    end

    test "and a finished run says which of the three ends it was", %{conn: conn, user: user} do
      %{scene: scene, wren: wren} = scene(user)
      {:ok, _} = Auto.start(scene, 1, enqueue: fn _ -> :ok end)

      :ok =
        App.dispatch(%ExitCharacter{scene_id: scene, character_id: to_string(wren.id), beat: 2})

      Auto.finish(scene, :empty)

      {:ok, view, html} = live(conn, ~p"/play/#{scene}")

      assert html =~ "Everyone has left."
      # And it can be taken off the bar without deleting the record of what happened.
      refute render_click(view, "clear_auto", %{}) =~ "Everyone has left."
      assert %{status: "done"} = Auto.get(scene)
    end
  end

  describe "running" do
    test "the scene advances more than one beat with nobody pressing anything",
         %{conn: conn, user: user} do
      %{scene: scene} = scene(user)

      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      view |> element("button[phx-click=start_auto]") |> render_click()
      GenServer.stop(view.pid, :shutdown)
      drain()

      # Continue's entire job is to stop after one beat. This is the claim that breaks
      # if the yield hint, the depth cap or the `auto` flag stops riding the chain.
      assert speeches(scene) > 1
      assert Auto.get(scene).beats_run > 1
    end

    test "and stops at the cap it was given", %{conn: conn, user: user} do
      %{scene: scene} = scene(user)

      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      GenServer.stop(view.pid, :shutdown)
      {:ok, _} = Auto.start(scene, 1, max_beats: 3)
      drain()

      run = Auto.get(scene)
      assert run.status == "done"
      assert run.beats_run <= 3
      assert run.ended_reason != nil
    end

    test "a paused run stops chaining", %{conn: conn, user: user} do
      %{scene: scene} = scene(user)

      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      GenServer.stop(view.pid, :shutdown)
      {:ok, _} = Auto.start(scene, 1, max_beats: 20)
      {:ok, _} = Auto.pause(scene)
      drain()

      # The beat already in flight is allowed to finish — it is generating, and throwing
      # it away costs the same money for nothing — but nothing after it runs.
      assert %{status: "paused"} = Auto.get(scene)
      assert Auto.get(scene).beats_run <= 1
    end
  end
end
