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

    {:ok, author, _html} = live(conn, ~p"/play/#{scene}")
    author_html = author |> element("button[phx-click=toggle_intros]") |> render_click()
    assert author_html =~ "The Director suggests"
    assert author_html =~ "Bram"
    assert author_html =~ "he&#39;s owed a debt"

    # A character viewer must never see the pending introduction (irony guarantee) —
    # and has no GM bar to open it from either.
    {:ok, _mira, mira_html} = live(conn, ~p"/play/#{scene}?as=mira")
    refute mira_html =~ "toggle_intros"
    refute mira_html =~ "The Director suggests"
    refute mira_html =~ "he&#39;s owed a debt"
  end

  test "admitting an existing character enters them and clears the proposal",
       %{conn: conn, user: user} do
    bram = character(user, "Bram")
    scene = scene_with_proposal("Bram")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
    html = view |> element("button[phx-click=toggle_intros]") |> render_click()
    # Existing full character → one-click Admit.
    assert html =~ "Admit"

    view |> element("button[phx-click=intro_admit][phx-value-name=Bram]") |> render_click()

    html = render(view)
    # Proposal gone — matched by *name* even though he entered by id (§5.2). With
    # nothing left to suggest, the drawer's button goes too.
    refute html =~ "toggle_intros"
    # Bram is a scene member: offered in the viewing-as roster keyed by his library
    # id, labelled with his name. The value is what routes; the label is what reads.
    assert html =~ ~s(<option value="#{bram.id}")
    assert html =~ ">Bram</option>"
  end

  test "generate & admit a brand-new name creates, fills, and enters them",
       %{conn: conn, user: user} do
    scene = scene_with_proposal("Ghost")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
    html = view |> element("button[phx-click=toggle_intros]") |> render_click()
    assert html =~ "Write &amp; admit"

    view |> element("button[phx-click=intro_generate][phx-value-name=Ghost]") |> render_click()
    generate(view)

    # A full character named Ghost now exists, owned by the author, and is in the scene.
    ghost =
      Enum.find(Library.list_for_owner(Owner.of(user)), &(Library.payload(&1).name == "Ghost"))

    assert ghost && Library.payload(ghost).status == :full
    # Entered under the library id the generation minted, displayed by name (§5.2).
    assert render(view) =~ ~s(<option value="#{ghost.id}")
    assert render(view) =~ ">Ghost</option>"
  end

  test "dismissing clears the proposal without entering anyone", %{conn: conn} do
    scene = scene_with_proposal("Bram")

    {:ok, view, _html} = live(conn, ~p"/play/#{scene}")
    view |> element("button[phx-click=toggle_intros]") |> render_click()
    view |> element("button[phx-click=intro_dismiss][phx-value-name=Bram]") |> render_click()

    html = render(view)
    # Nothing left to suggest, so the drawer's own button goes with the proposal.
    refute html =~ "toggle_intros"
    refute html =~ ~s(<option value="Bram")
  end
end
