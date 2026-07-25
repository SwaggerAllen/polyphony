defmodule PolyphonyWeb.PlayLiveTest do
  @moduledoc """
  The headline frontend test: the dramatic-irony guarantee holds *through the UI*. A
  whisper committed from the composer is visible to the omniscient author view and to
  the addressee's view, and **silently absent** from a bystander's view — the same
  `visible_to?` projection play runs on, exercised end-to-end through the LiveView.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.App
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  setup :register_and_log_in_user

  defp scene_with_cast do
    scene = "webt-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})

    for c <- ~w(mira otto cara),
        do: :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: c, beat: 1})

    scene
  end

  test "a whisper reaches the author and addressee but is absent for a bystander", %{conn: conn} do
    scene = scene_with_cast()

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    view
    |> form("form[phx-submit=say]", %{as: "mira", to: "otto", text: "meet me at dawn"})
    |> render_submit()

    # Omniscient author view sees the whisper.
    assert render(view) =~ "meet me at dawn"

    # A bystander (cara) — a scene member, but not addressed — must not see it.
    {:ok, _cara, cara_html} = live(conn, ~p"/play/#{scene}?as=cara")
    refute cara_html =~ "meet me at dawn"

    # The addressee (otto) does.
    {:ok, _otto, otto_html} = live(conn, ~p"/play/#{scene}?as=otto")
    assert otto_html =~ "meet me at dawn"
  end

  test "an ordinary (aloud) line is visible to every member's view", %{conn: conn} do
    scene = scene_with_cast()
    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")

    view
    |> form("form[phx-submit=say]", %{as: "cara", to: "", text: "lovely weather"})
    |> render_submit()

    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{scene}?as=mira")
    assert mira_html =~ "lovely weather"
  end
end
