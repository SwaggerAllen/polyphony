defmodule PolyphonyWeb.PlayDebugLiveTest do
  @moduledoc "The debug drawer's Events toggle swaps the scene pane to the raw event stream."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, DebugFlags}
  alias PolyphonyCore.Commands.{OpenScene, EnterCharacter}

  setup :register_and_log_in_user

  setup do
    previous = DebugFlags.get(:events)
    on_exit(fn -> Application.put_env(:polyphony, :debug_events, previous) end)
    :ok
  end

  defp scene do
    s = "dbg-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: s, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: s, character_id: "mira", beat: 1})
    s
  end

  test "toggling Events (from the sibling drawer) shows the raw event stream", %{conn: conn} do
    s = scene()
    {:ok, view, html} = live(conn, ~p"/play/#{s}")
    refute html =~ "raw event stream"

    # The toggle lives in the debug drawer — a separate LiveView — so it broadcasts.
    DebugFlags.set(:events, true)

    html = render(view)
    assert html =~ "Debug timeline"
    assert html =~ "SceneOpened"
    assert html =~ "CharacterEntered"
  end

  test "the raw stream is author-only — a character view never shows it", %{conn: conn} do
    s = scene()
    DebugFlags.set(:events, true)

    {:ok, _view, html} = live(conn, ~p"/play/#{s}?as=mira")
    refute html =~ "raw event stream"
  end
end
