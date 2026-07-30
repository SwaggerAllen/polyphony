defmodule PolyphonyWeb.PlayComposeLiveTest do
  @moduledoc "The composer's ✨ Expand button drafts a turn from the character's view (§11)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Context, Library, Owner}
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

  test "Expand rebuilds a cold context (ETS cache miss) instead of erroring", %{
    conn: conn,
    user: user
  } do
    # A scene whose per-character context was never cached (e.g. after a restart), but
    # the character exists in the author's library so the sheet is resolvable.
    Library.put(%{
      owner: Owner.of(user),
      kind: "character",
      payload: %CharacterSheet{name: "mira", premise: "A wary tidewarden.", status: :full}
    })

    scene = "cold-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})
    # NOTE: no Store.put — the context cache is cold.

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")
    view |> element("#say-input") |> render_hook("compose", %{"text" => "greet them"})
    # Rebuilding a cold context does real embed + retrieval work, so allow more time.
    render_async(view, 2_000)

    assert_push_event(view, "set_composer", %{text: text})
    assert is_binary(text) and String.trim(text) != ""
  end

  defmodule Rate429Provider do
    @behaviour Polyphony.LLM.Provider
    @impl true
    def complete(_messages, _opts),
      do: {:error, {:http_status, 429, ~s({"error":{"code":"engine_overloaded"}})}}
  end

  test "a failed Expand shows a specific reason, not a generic error", %{conn: conn} do
    scene = scene_with_mira()
    Application.put_env(:polyphony, :llm, provider: Rate429Provider)

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}?as=mira")
    view |> element("#say-input") |> render_hook("compose", %{"text" => "greet them"})
    render_async(view)

    # The rate-limit reason is surfaced through Suggest → compose_error, not swallowed.
    assert render(view) =~ "rate-limited"
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
