defmodule PolyphonyWeb.PlayComposeLiveTest do
  @moduledoc "The composer's ✨ Expand button drafts a turn from the character's view (§11)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Context}
  alias Polyphony.Context.Store
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp scene_with_mira do
    scene = "cmp-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})

    sheet = %CharacterSheet{name: "mira", premise: "A wary tidewarden.", voice: "clipped"}

    ctx =
      Context.materialize(scene_id: scene, character_id: "mira", sheet: sheet, premise: "A hall.")

    Store.put(scene, "mira", ctx)

    scene
  end

  test "Expand drafts a turn and pushes it into the composer (never auto-commits)", %{conn: conn} do
    scene = scene_with_mira()
    {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

    # The ✨ button pushes "compose" through the composer hook with the current draft.
    view |> element("#say-input") |> render_hook("compose", %{"text" => "greet them warily"})
    render_async(view)

    assert_push_event(view, "set_composer", %{text: text})
    assert is_binary(text) and String.trim(text) != ""

    # Nothing was committed — the draft only populates the composer.
    refute render(view) =~ "phx-value-packet"
  end

  test "the composer commits a whole turn — thoughts and actions, not only speech", %{conn: conn} do
    scene = scene_with_mira()
    {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")

    view
    |> form("form[phx-submit=say]", %{text: "thinks: stay sharp\nWelcome.\ndoes: bars the door"})
    |> render_submit()

    html = render(view)
    assert html =~ "Welcome."
    assert html =~ "stay sharp"
    assert html =~ "bars the door"
  end
end
