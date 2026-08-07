defmodule PolyphonyWeb.PlayTurnsLiveTest do
  @moduledoc "Editing / deleting / rerolling committed turns within a beat (§7 supersede-and-recommit)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.App
  alias PolyphonyCore.Packets
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.{Move, SelfState}
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Events.{SpeechUttered, ThoughtOccurred, ActionTaken}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp scene_with_turn(text) do
    scene = "turn-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    packet = %TurnPacket{
      moves: [%Move{seq: 1, type: :speech, content: text}],
      self_state: %SelfState{}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "mira",
        beat: 1,
        packet_id: BeatOps.packet_id(scene, 1, "mira"),
        packet: packet,
        edited: true
      })

    scene
  end

  # Two turns in one beat: Bram's is written *after* Mira's and therefore on top of it,
  # which is the whole reason `:invalid` exists.
  defp two_turn_scene do
    scene = scene_with_turn("She agrees.")
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "bram", beat: 1})

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: "bram",
        beat: 1,
        packet_id: BeatOps.packet_id(scene, 1, "bram"),
        packet: %TurnPacket{
          moves: [%Move{seq: 1, type: :speech, content: "Then we sail."}],
          self_state: %SelfState{}
        },
        edited: true
      })

    scene
  end

  defp transcript_of(scene), do: Enum.join(canonical_speech(scene), " | ")

  defp canonical_speech(scene) do
    scene
    |> BeatOps.stored_events()
    |> Packets.canonical()
    |> Enum.filter(&match?(%SpeechUttered{}, &1))
    |> Enum.map(& &1.content)
  end

  defp canonical_kind(scene, struct) do
    scene
    |> BeatOps.stored_events()
    |> Packets.canonical()
    |> Enum.filter(&(&1.__struct__ == struct))
    |> Enum.map(& &1.content)
  end

  defp commit_action(scene, character, content) do
    packet = %TurnPacket{
      moves: [%Move{seq: 1, type: :action, content: content}],
      self_state: %SelfState{}
    }

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: character,
        beat: 1,
        packet_id: BeatOps.packet_id(scene, 1, character),
        packet: packet,
        edited: true
      })
  end

  test "an action is shown as written — the turn is attributed once, at its head", %{conn: conn} do
    scene = "turn-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "Todd", beat: 1})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "Lydia", beat: 1})

    commit_action(scene, "Todd", "Todd snaps his head toward her.")
    commit_action(scene, "Lydia", "reaches out a trembling hand.")

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

    # The design gives each turn one heading with the actor's name, so a move never
    # repeats it — which also ends the old "Todd Todd" doubling, without the
    # does-it-already-start-with-the-name guess that used to prevent it.
    assert html =~ "Todd snaps his head toward her."
    refute html =~ "Todd Todd"

    # A bare action stays bare: whose it is has already been said above it.
    assert html =~ "reaches out a trembling hand."
    refute html =~ "Lydia reaches out a trembling hand."

    # ...and that's where it's said — the block's heading, in her voice colour.
    assert html =~ ~r{ttl[^>]*>\s*Lydia\s*<}
  end

  test "turn controls are author-only", %{conn: conn} do
    scene = scene_with_turn("Original line.")

    {:ok, _author, html} = live(conn, ~p"/play/#{scene}")
    assert html =~ "phx-click=\"reroll_turn\""
    assert html =~ "phx-click=\"delete_turn\""

    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{scene}?as=mira")
    refute mira_html =~ "phx-click=\"delete_turn\""
  end

  test "deleting a turn removes it from the canonical transcript", %{conn: conn} do
    scene = scene_with_turn("Delete me.")
    pid = BeatOps.packet_id(scene, 1, "mira")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    view
    |> element("button[phx-click=delete_turn][phx-value-packet='#{pid}']")
    |> render_click()

    assert canonical_speech(scene) == []
    refute render(view) =~ "Delete me."
  end

  test "editing a turn supersedes the old take and commits the rewrite", %{conn: conn} do
    scene = scene_with_turn("Old words.")
    pid = BeatOps.packet_id(scene, 1, "mira")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    view |> element("button[phx-click=edit_turn][phx-value-packet='#{pid}']") |> render_click()

    view
    |> form("form[phx-submit=save_edit]", %{
      "beat" => "1",
      "character" => "mira",
      "packet" => pid,
      "text" => "New words entirely."
    })
    |> render_submit()

    assert canonical_speech(scene) == ["New words entirely."]
    assert render(view) =~ "New words entirely."
    refute render(view) =~ "Old words."
  end

  test "editing rewrites the whole turn — thought and action, not just speech",
       %{conn: conn} do
    scene = scene_with_turn("Old words.")
    pid = BeatOps.packet_id(scene, 1, "mira")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    view |> element("button[phx-click=edit_turn][phx-value-packet='#{pid}']") |> render_click()

    view
    |> form("form[phx-submit=save_edit]", %{
      "beat" => "1",
      "character" => "mira",
      "packet" => pid,
      "text" => "thinks: I should stay wary.\nWelcome.\ndoes: draws the bolt"
    })
    |> render_submit()

    assert canonical_speech(scene) == ["Welcome."]
    assert canonical_kind(scene, ThoughtOccurred) == ["I should stay wary."]
    assert canonical_kind(scene, ActionTaken) == ["draws the bolt"]
    refute render(view) =~ "Old words."
  end

  describe "an edit that changes what happened" do
    test "forks here, keeps the original, and takes you to the branch", %{conn: conn} do
      scene = two_turn_scene()
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

      view
      |> element(
        ~s(button[phx-click="edit_turn"][phx-value-packet="#{BeatOps.packet_id(scene, 1, "mira")}"])
      )
      |> render_click()

      # The checkbox `Edit.edit/6` has always asked for and nothing ever put to anybody.
      result =
        view
        |> form(~s(form[phx-submit="save_edit"]), %{
          text: "She refuses.",
          invalidates: "true"
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/play/" <> branch}}} = result
      refute branch == scene

      # The original timeline survives intact — that is the whole reason this forks
      # rather than editing in place.
      assert transcript_of(scene) =~ "She agrees."
      refute transcript_of(scene) =~ "She refuses."

      # And the branch carries the correction with the stale tail discarded: the second
      # turn was written on top of the line that just changed.
      branch_text = transcript_of(branch)
      assert branch_text =~ "She refuses."
      refute branch_text =~ "Then we sail."
    end

    test "leaving it unticked corrects in place, as it always did", %{conn: conn} do
      scene = two_turn_scene()
      {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

      view
      |> element(
        ~s(button[phx-click="edit_turn"][phx-value-packet="#{BeatOps.packet_id(scene, 1, "mira")}"])
      )
      |> render_click()

      html =
        view
        |> form(~s(form[phx-submit="save_edit"]), %{text: "She agrees, warily."})
        |> render_submit()

      # Same scene, and the tail is untouched: a typo didn't change what happened.
      assert html =~ "She agrees, warily."
      assert html =~ "Then we sail."
    end
  end
end
