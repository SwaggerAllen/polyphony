defmodule PolyphonyWeb.PlayIntroductionsLiveTest do
  @moduledoc """
  The play-view resolution of Director introduction proposals: the queue is
  author-only (omniscient), admitting an existing character enters them mid-scene,
  generating a brand-new name creates + fills + enters, and dismiss clears it.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library, Owner}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{OpenScene, EnterCharacter, ProposeIntroduction}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp scene_with_proposal(name, reason \\ "arrives") do
    scene = "intro-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0})
    :ok = App.dispatch(%EnterCharacter{scene_id: scene, character_id: "mira", beat: 1})
    :ok = App.dispatch(%ProposeIntroduction{scene_id: scene, beat: 2, name: name, reason: reason})
    scene
  end

  defp character(user, name),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: name, status: :full}
      })

  test "the introduction queue is author-only (omniscient)", %{conn: conn} do
    scene = scene_with_proposal("Bram", "he's owed a debt")

    {:ok, _author, author_html} = live(conn, ~p"/play/#{scene}")
    assert author_html =~ "wants to bring characters on"
    assert author_html =~ "Bram"
    assert author_html =~ "he&#39;s owed a debt"

    # A character viewer must never see the pending introduction (irony guarantee).
    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{scene}?as=mira")
    refute mira_html =~ "wants to bring characters on"
    refute mira_html =~ "he&#39;s owed a debt"
  end

  test "admitting an existing character enters them and clears the proposal",
       %{conn: conn, user: user} do
    character(user, "Bram")
    scene = scene_with_proposal("Bram")

    {:ok, view, html} = live(conn, ~p"/play/#{scene}")
    # Existing full character → one-click Admit.
    assert html =~ "Admit"

    view |> element("button[phx-click=intro_admit][phx-value-name=Bram]") |> render_click()

    html = render(view)
    # Proposal gone; Bram is now a scene member (offered in the viewing-as roster).
    refute html =~ "wants to bring characters on"
    assert html =~ ~s(<option value="Bram")
  end

  test "generate & admit a brand-new name creates, fills, and enters them",
       %{conn: conn, user: user} do
    scene = scene_with_proposal("Ghost")

    {:ok, view, html} = live(conn, ~p"/play/#{scene}")
    assert html =~ "Generate &amp; admit"

    view |> element("button[phx-click=intro_generate][phx-value-name=Ghost]") |> render_click()
    render_async(view)

    # A full character named Ghost now exists, owned by the author, and is in the scene.
    ghost =
      Enum.find(Library.list_for_owner(Owner.of(user)), &(Library.payload(&1).name == "Ghost"))

    assert ghost && Library.payload(ghost).status == :full
    assert render(view) =~ ~s(<option value="Ghost")
  end

  test "dismissing clears the proposal without entering anyone", %{conn: conn} do
    scene = scene_with_proposal("Bram")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
    view |> element("button[phx-click=intro_dismiss][phx-value-name=Bram]") |> render_click()

    html = render(view)
    refute html =~ "wants to bring characters on"
    refute html =~ ~s(<option value="Bram")
  end
end
