defmodule PolyphonyWeb.PlayStreamLiveTest do
  @moduledoc """
  The transcript is a LiveView stream keyed by beat, and the rule that comes with it.

  `phx-update="stream"` means **the client only touches nodes the server explicitly
  re-inserts.** Re-rendering is no longer enough: assign anything that changes how a beat
  looks, and the beat keeps the markup it was last sent.

  That is not obvious and it is silent — the render function is correct, the assign is
  correct, and the screen is stale. It cost four tests in `PlayTurnsLiveTest` looking for
  an edit form that was never sent, and those tests would fail again for the same reason
  without saying why. This one says why.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library, Owner}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Director.BeatOps
  alias PolyphonyCore.Commands.{CommitPacket, EnterCharacter, OpenScene}
  alias PolyphonyCore.TurnPacket
  alias PolyphonyCore.TurnPacket.Move

  setup :register_and_log_in_user

  defp scene_with_turn(user, content) do
    wren =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full}
      })

    scene = "st-" <> Integer.to_string(System.unique_integer([:positive]))
    id = to_string(wren.id)

    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: id, beat: 1})

    :ok =
      App.dispatch(%CommitPacket{
        scene_id: scene,
        character_id: id,
        beat: 1,
        packet_id: BeatOps.packet_id(scene, 1, id),
        packet: %TurnPacket{moves: [%Move{seq: 1, type: :speech, content: content}]},
        edited: true
      })

    %{scene: scene, wren: id}
  end

  test "the transcript is a stream container of beats", %{conn: conn, user: user} do
    %{scene: scene} = scene_with_turn(user, "Nothing came in tonight.")

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}")

    assert html =~ ~s(phx-update="stream")
    # Keyed by the beat's own number — that is what makes a re-insert land on the node it
    # replaces rather than appending a second copy of the beat.
    assert html =~ ~s(id="beat-1")
    assert html =~ "Nothing came in tonight."
  end

  test "an assign that changes a beat must re-insert it, or the screen goes stale", ctx do
    %{conn: conn, user: user} = ctx
    %{scene: scene, wren: wren} = scene_with_turn(user, "Nothing came in tonight.")

    {:ok, view, html} = live(conn, ~p"/play/#{scene}")
    refute html =~ ~s(phx-submit="save_edit")

    # `edit_turn` only assigns `editing`. Under a stream that is invisible until the beat
    # holding this turn is sent again — so if this fails, look for a `stream_beats/2` call
    # that went missing rather than at the markup, which will be perfectly correct.
    html =
      view
      |> element("button[phx-click=edit_turn][phx-value-packet='#{packet(scene, wren)}']")
      |> render_click()

    assert html =~ ~s(phx-submit="save_edit")

    # And back again: cancelling has the same problem in the other direction, where the
    # form would stay on screen after the state that put it there is gone.
    html = view |> element("button[phx-click=cancel_edit]") |> render_click()
    refute html =~ ~s(phx-submit="save_edit")
  end

  test "a turn arriving over the wire lands in its beat", %{conn: conn, user: user} do
    %{scene: scene} = scene_with_turn(user, "Nothing came in tonight.")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    send(
      view.pid,
      {:polyphony_event,
       %{
         type: "event.committed",
         seq: 99,
         kind: "SpeechUttered",
         payload: %{
           packet_id: "later-packet",
           speaker_id: "wren",
           beat: 2,
           content: "Then we agree it was nothing."
         }
       }}
    )

    html = render(view)
    assert html =~ "Then we agree it was nothing."
    # A new beat is a new node rather than a rewrite of the one before it.
    assert html =~ ~s(id="beat-2")
    assert html =~ "Nothing came in tonight."
  end

  defp packet(scene, character), do: BeatOps.packet_id(scene, 1, character)
end
