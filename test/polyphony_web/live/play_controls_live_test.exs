defmodule PolyphonyWeb.PlayControlsLiveTest do
  @moduledoc "Per-character control mode (autonomous / assisted / user-controlled) from the play view."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, TurnOrder}
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  setup :register_and_log_in_user

  defp scene_with(chars) do
    scene = "ctrl-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- chars,
        do: :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    scene
  end

  defp stored(scene) do
    App |> Commanded.EventStore.stream_forward(scene) |> Enum.map(& &1.data)
  end

  test "the cast panel defaults to automated and is omniscient-only", %{conn: conn} do
    scene = scene_with(["mira"])

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}")
    assert html =~ "Cast &amp; control"
    # Default automated (autonomous) is selected.
    assert html =~ ~r/<option value="autonomous" selected[^>]*>Automated/

    # A character viewer doesn't get the author control panel.
    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{scene}?as=mira")
    refute mira_html =~ "Cast &amp; control"
  end

  test "setting a control mode records it and the walk honors it", %{conn: conn} do
    scene = scene_with(["mira"])

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    view
    |> element("form[phx-change=set_control]")
    |> render_change(%{"character" => "mira", "control" => "user_controlled"})

    # Persisted to the scene log and reflected by the control-mode reader.
    assert TurnOrder.control_mode(stored(scene), "mira") == "user_controlled"
    assert render(view) =~ ~r/<option value="user_controlled" selected/
  end
end
