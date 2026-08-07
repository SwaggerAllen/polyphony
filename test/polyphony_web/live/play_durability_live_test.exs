defmodule PolyphonyWeb.PlayDurabilityLiveTest do
  @moduledoc """
  What survives the tab going away mid-turn.

  These waits are seconds long, on a screen people read on a phone — so "the author
  looks at something else while a turn is written" is the normal case, not the edge one.
  Two separate mechanisms carry it, and the distinction is worth keeping straight:

  **The fiction is never in the browser.** A cast turn is `Jobs.GeneratePacket` and the
  Director is `Jobs.RunBeat`; both dispatch commands, and the log is the source of
  truth. The LiveView is a *viewer* — closing it stops the reading, not the scene. The
  first test here pins that with no LiveView involved at all, because it is the property
  everything else on this screen assumes.

  **The authoring aids park their answers.** ✦ Expand, ✦ Narrate and Write-them-in run
  through `Polyphony.Generations` — a job produces the raw result, the screen decides
  what it means — so a result that lands while nobody is watching waits on a row instead
  of dying with the socket.

  What was missing was the third state: *still running*. `restore_generations/1` brought
  back the composer's spinner and nothing else, so a reconnect mid-narration or
  mid-write-in came back looking **idle**. That is worse than looking stuck, because the
  control is live again and pressing it replaces the claim — throwing away an answer
  that was seconds away and paying for a second one.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Generations, Library, SceneControl}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.Commands.{DeclareTurnOrder, EnterCharacter, OpenScene}
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Events.{SpeechUttered, ThoughtOccurred}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    # Killing a LiveView on purpose, repeatedly.
    Process.flag(:trap_exit, true)
    :ok
  end

  defp character(user, name, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name, status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp campaign(user, ids),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{kind: :campaign, name: "Camp", character_ids: ids, bible_id: nil, scenes: []}
      })

  defp scene(present, campaign_id \\ nil) do
    id = "dur-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: id, opened_beat: 0, campaign_id: campaign_id})

    for c <- present,
        do:
          :ok =
            App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(c.id), beat: 1})

    id
  end

  defp drain do
    Oban.drain_queue(queue: :generation, with_recursion: true, with_scheduled: true)
    Oban.drain_queue(queue: :director, with_recursion: true, with_scheduled: true)
  end

  defp close(view), do: GenServer.stop(view.pid, :shutdown)

  describe "the turn itself" do
    test "lands with nobody watching at all", %{user: user} do
      wren = character(user, "Wren", %{premise: "She counts the manifests twice."})
      id = scene([wren])

      # No LiveView is ever mounted in this test. The loop is Oban and Commanded; the
      # browser is a reader of the log, and it is not on the path a turn takes to reach
      # it. If this ever stops being true, every waiting state on the screen becomes a
      # promise the backend can't keep.
      :ok =
        App.dispatch(%DeclareTurnOrder{scene_id: id, beat: 1, order: [to_string(wren.id)]})

      SceneControl.continue(id, 1, args: %{"control_hint" => "yield_to_user"})
      for _ <- 1..4, do: drain()

      events = BeatOps.stored_events(id)

      assert Enum.any?(events, &match?(%SpeechUttered{}, &1))
      # And the private half too — the parts only she sees are written by the same job.
      assert Enum.any?(events, &match?(%ThoughtOccurred{}, &1))
    end
  end

  describe "✦ Expand in the composer" do
    setup %{user: user} do
      wren = character(user, "Wren")
      %{scene: scene([wren]), wren: wren}
    end

    test "comes back as a spinner while it is still running",
         %{conn: conn, scene: scene, wren: wren} do
      {:ok, view, _} = live(conn, ~p"/play/#{scene}?as=#{wren.id}")
      render_click(view, "compose", %{"text" => "She looks at the ledger."})
      close(view)

      # Deliberately not drained: the job is still queued, which is the state a reconnect
      # lands in most often.
      assert "compose" in Generations.running(scene)

      {:ok, view2, _} = live(conn, ~p"/play/#{scene}?as=#{wren.id}")
      assert render(view2) =~ "✦ …"
      close(view2)
    end

    test "a draft finished while away arrives on the next visit",
         %{conn: conn, scene: scene, wren: wren} do
      {:ok, view, _} = live(conn, ~p"/play/#{scene}?as=#{wren.id}")
      render_click(view, "compose", %{"text" => "She looks at the ledger."})
      close(view)
      drain()

      {:ok, view2, _} = live(conn, ~p"/play/#{scene}?as=#{wren.id}")

      # The composer's text is client state, so the draft is handed over as an event
      # rather than rendered — the same one a live delivery uses.
      assert_push_event(view2, "set_composer", %{text: text})
      assert is_binary(text) and text != ""

      # Read exactly once: the row is consumed, so a second tab can't apply it again.
      assert Generations.take(scene) == []
      close(view2)
    end
  end

  describe "✦ Expand in the narrate panel" do
    setup do
      %{scene: scene([])}
    end

    test "comes back as a spinner, in a panel that is open to show it",
         %{conn: conn, scene: scene} do
      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      render_click(view, "narrate_open", %{})
      render_click(view, "expand_narrate", %{})
      close(view)

      {:ok, view2, html} = live(conn, ~p"/play/#{scene}")

      # Both halves matter. The panel is closed on mount, so restoring only the flag
      # would leave the narration being written behind a drawer — indistinguishable
      # from nothing happening, which is the state that gets ✦ pressed twice.
      assert html =~ "✦ …"
      assert html =~ ~s(phx-submit="narrate")
      close(view2)
    end

    test "a narration finished while away opens the panel with it in", %{conn: conn} do
      scene = scene([])
      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      render_click(view, "narrate_open", %{})
      render_click(view, "expand_narrate", %{})
      close(view)
      drain()

      {:ok, view2, _} = live(conn, ~p"/play/#{scene}")
      html = render(view2)

      assert html =~ ~s(id="narrate-input")
      refute html =~ "✦ …"
      assert Generations.take(scene) == []
      close(view2)
    end
  end

  describe "writing a walk-on in" do
    test "the row keeps its spinner, so the button can't be pressed twice",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      bellman = character(user, "The bellman", %{status: :stub})
      camp = campaign(user, [wren.id, bellman.id])
      scene = scene([wren], camp.id)

      {:ok, view, _} = live(conn, ~p"/play/#{scene}")
      render_click(view, "toggle_cast", %{})
      render_click(view, "write_in", %{"id" => to_string(bellman.id)})
      close(view)

      assert "write_in:#{bellman.id}" in Generations.running(scene)

      {:ok, view2, _} = live(conn, ~p"/play/#{scene}")
      html = view2 |> render_click("toggle_cast", %{})

      # Pressing it again claims the key afresh, which drops the answer already on its
      # way. So the control stays held for as long as the work is.
      assert html =~ ~r/<button[^>]*disabled[^>]*phx-click="write_in"/
      close(view2)
    end
  end
end
