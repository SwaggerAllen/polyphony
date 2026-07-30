defmodule PolyphonyWeb.PlayProgressLiveTest do
  @moduledoc """
  The beat-loop progress indicator (§13): every viewer sees what's running now (Director
  / which character), input is blocked while a beat advances, and — critically — an
  `:idle` announce reliably clears it (the "done" signal the transcript stream lacked).
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Broadcast}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  setup :register_and_log_in_user

  defp scene do
    s = "prog-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: s, character_id: "Lydia", beat: 1})
    s
  end

  test "granular phase text, input blocked while busy, cleared on idle", %{conn: conn} do
    s = scene()
    {:ok, view, _html} = live(conn, ~p"/play/#{s}?as=Lydia")

    # Idle at rest: the composer is usable, no activity line.
    refute render(view) =~ "writing their turn"
    refute has_element?(view, "button[type=submit][disabled]")

    # Director deciding → shown, and both Send and the composer are blocked.
    Broadcast.announce_progress(s, :director, beat: 2)
    html = render(view)
    assert html =~ "The director is setting the scene"
    assert has_element?(view, "button[type=submit][disabled]")
    assert has_element?(view, "#say-input[disabled]")

    # A named character generating → named, still blocked.
    Broadcast.announce_progress(s, :generating, subject: "Todd", beat: 2)
    assert render(view) =~ "Todd is writing their turn"
    assert has_element?(view, "button[type=submit][disabled]")

    # Idle → indicator gone, input restored (the reliable clear).
    Broadcast.announce_progress(s, :idle, beat: 2)
    html = render(view)
    refute html =~ "writing their turn"
    refute html =~ "setting the scene"
    refute has_element?(view, "button[type=submit][disabled]")
    refute has_element?(view, "#say-input[disabled]")
  end
end
