defmodule PolyphonyWeb.PlayTraceLiveTest do
  @moduledoc "The debug pane shows the actual Director + character LLM requests/responses."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Context, DebugFlags, DebugTap}
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}
  alias Polyphony.Jobs.RunBeat

  @mock "Elixir.Polyphony.LLM.Mock"

  setup :register_and_log_in_user

  setup do
    prev_llm = Application.get_env(:polyphony, :llm)
    prev_trace = DebugFlags.get(:trace)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    DebugFlags.set(:trace, true)

    on_exit(fn ->
      Application.put_env(:polyphony, :llm, prev_llm)
      Application.put_env(:polyphony, :debug_trace, prev_trace)
    end)

    :ok
  end

  test "captured Director and character calls render in the debug pane", %{conn: conn} do
    scene = "trc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    sheet = %CharacterSheet{name: "mira", premise: "wary", voice: "clipped"}

    Store.put(
      scene,
      "mira",
      Context.materialize(scene_id: scene, character_id: "mira", sheet: sheet, premise: "A hall.")
    )

    Oban.Testing.with_testing_mode(:inline, fn ->
      RunBeat.enqueue(%{
        "scene_id" => scene,
        "beat" => 2,
        "provider" => @mock,
        "control_hint" => "yield_to_user"
      })
    end)

    DebugTap.flush()

    # Both the Director decision and the character turn were captured for this scene.
    subjects = DebugTap.recent(scene) |> Enum.map(& &1.subject) |> Enum.uniq()
    assert "director" in subjects
    assert "mira" in subjects

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}")
    assert html =~ "Debug: LLM calls"
    assert html =~ "director"
    assert html =~ "mira"
  end

  test "traces are author-only — a character view never shows them", %{conn: conn} do
    scene = "trc-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    DebugTap.record(%{
      scene_id: scene,
      subject: "director",
      params: [],
      request: [],
      response: {:ok, "x"}
    })

    DebugTap.flush()

    {:ok, _view, html} = live(conn, ~p"/play/#{scene}?as=mira")
    refute html =~ "Debug: LLM calls"
  end
end
