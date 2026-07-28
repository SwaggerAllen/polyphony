defmodule PolyphonyWeb.PlayTurnsLiveTest do
  @moduledoc "Editing / deleting / rerolling committed turns within a beat (§7 supersede-and-recommit)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Packets}
  alias Polyphony.TurnPacket
  alias Polyphony.TurnPacket.{Move, SelfState}
  alias Polyphony.Commands.{OpenScene, EnterCharacter, CommitPacket}
  alias Polyphony.Director.BeatOps
  alias Polyphony.Events.SpeechUttered

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

  defp canonical_speech(scene) do
    scene
    |> BeatOps.stored_events()
    |> Packets.canonical()
    |> Enum.filter(&match?(%SpeechUttered{}, &1))
    |> Enum.map(& &1.content)
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
end
