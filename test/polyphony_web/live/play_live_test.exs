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

  test "a whisper (inferred from the text) reaches author + addressee, not a bystander",
       %{conn: conn} do
    scene = scene_with_cast()

    # You speak as whoever you're viewing as; the whisper is inferred from the text.
    {:ok, mira, _html} = live(conn, ~p"/play/#{scene}?as=mira")

    mira
    |> form("form[phx-submit=say]", %{text: "(whisper to otto: meet me at dawn)"})
    |> render_submit()

    # Omniscient author view sees the whisper.
    {:ok, _author, author_html} = live(conn, ~p"/play/#{scene}")
    assert author_html =~ "meet me at dawn"

    # A bystander (cara) — a scene member, but not addressed — must not see it.
    {:ok, _cara, cara_html} = live(conn, ~p"/play/#{scene}?as=cara")
    refute cara_html =~ "meet me at dawn"

    # The addressee (otto) does.
    {:ok, _otto, otto_html} = live(conn, ~p"/play/#{scene}?as=otto")
    assert otto_html =~ "meet me at dawn"
  end

  test "one submission can say a line aloud and whisper another", %{conn: conn} do
    scene = scene_with_cast()
    {:ok, mira, _html} = live(conn, ~p"/play/#{scene}?as=mira")

    mira
    |> form("form[phx-submit=say]", %{text: "Lovely weather. (whisper to otto: meet me at dawn)"})
    |> render_submit()

    # A bystander sees the aloud line but not the whisper.
    {:ok, _cara, cara_html} = live(conn, ~p"/play/#{scene}?as=cara")
    assert cara_html =~ "Lovely weather."
    refute cara_html =~ "meet me at dawn"

    # The addressee sees both.
    {:ok, _otto, otto_html} = live(conn, ~p"/play/#{scene}?as=otto")
    assert otto_html =~ "Lovely weather."
    assert otto_html =~ "meet me at dawn"
  end

  test "you speak as whoever you view as, and omniscient is read-only", %{conn: conn} do
    scene = scene_with_cast()

    # Omniscient view offers no composer input, just a hint to pick a character.
    {:ok, _author, author_html} = live(conn, ~p"/play/#{scene}")
    refute author_html =~ ~s(id="say-input")
    assert author_html =~ "pick a character above to speak"

    # As cara, an aloud line is visible to every member's view.
    {:ok, cara, _html} = live(conn, ~p"/play/#{scene}?as=cara")
    cara |> form("form[phx-submit=say]", %{text: "lovely weather"}) |> render_submit()

    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{scene}?as=mira")
    assert mira_html =~ "lovely weather"
  end
end
