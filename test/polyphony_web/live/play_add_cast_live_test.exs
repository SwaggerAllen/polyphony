defmodule PolyphonyWeb.PlayAddCastLiveTest do
  @moduledoc """
  Bringing a latecomer into a scene that is already running.

  Now that a scene opens with the cast the author *picked* rather than everyone the
  campaign has, the rest of the campaign has to be reachable from the play screen — or
  the only way to add somebody at beat nine is to start the scene over.

  It routes through the same `admit/3` an accepted Director introduction takes, so a
  character walked in by hand and one the Director asked for arrive identically: they
  enter at the current beat and know only what the scene has shown since.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{EnterCharacter, OpenScene}
  alias Polyphony.Events.CharacterEntered

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, name, status \\ :full),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: name, status: status}
      })

  defp campaign(user, ids),
    do:
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{kind: :campaign, name: "Camp", character_ids: ids, bible_id: nil, scenes: []}
      })

  # A scene that opened with only `present` in it, the way the scenes tab now opens one.
  defp scene(campaign_id, present) do
    id = "add-cast-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: id, opened_beat: 0, campaign_id: campaign_id})

    for c <- present,
        do:
          :ok =
            App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(c.id), beat: 1})

    id
  end

  # Only what the picker itself offers. `<option value="…">Name</option>` also renders
  # in the "viewing as" roster at the top of the screen, so an unscoped match would read
  # a member as an offer.
  defp offered(html) do
    case Regex.run(~r|<select id="scene-add-select".*?>(.*?)</select>|s, html) do
      [_, inner] -> for [_, id] <- Regex.scan(~r|<option value="([^"]+)"|, inner), do: id
      nil -> []
    end
  end

  defp members(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Enum.filter(&match?(%CharacterEntered{}, &1))
    |> Enum.map(& &1.character_id)
  end

  test "the cast panel offers the campaign's people who aren't here yet",
       %{conn: conn, user: user} do
    wren = character(user, "Wren")
    bram = character(user, "Bram")
    camp = campaign(user, [wren.id, bram.id])
    id = scene(camp.id, [wren])

    {:ok, view, _html} = live(conn, ~p"/play/#{id}")
    html = view |> element("button[phx-click=toggle_cast]") |> render_click()

    # Bram is the campaign's and not on stage; Wren is already here, so the picker
    # offers exactly one person.
    assert offered(html) == [to_string(bram.id)]
  end

  test "bringing one in enters them at the current beat", %{conn: conn, user: user} do
    wren = character(user, "Wren")
    bram = character(user, "Bram")
    camp = campaign(user, [wren.id, bram.id])
    id = scene(camp.id, [wren])

    {:ok, view, _html} = live(conn, ~p"/play/#{id}")
    view |> element("button[phx-click=toggle_cast]") |> render_click()
    view |> form("#scene-add-cast", %{id: to_string(bram.id)}) |> render_submit()

    assert to_string(bram.id) in members(id)

    # And the picker no longer offers him, because he is the roster now.
    refute to_string(bram.id) in offered(render(view))
  end

  test "a pending stub is offered to be written, not to be brought in",
       %{conn: conn, user: user} do
    wren = character(user, "Wren")
    stub = character(user, "The bellman", :stub)
    camp = campaign(user, [wren.id, stub.id])
    id = scene(camp.id, [wren])

    {:ok, view, _html} = live(conn, ~p"/play/#{id}")
    html = view |> element("button[phx-click=toggle_cast]") |> render_click()

    # `SceneControl` refuses a non-`:full` character, so they can't be an option in the
    # picker. The honest offer is *write them, then bring them in* — and without it a
    # side character the scene actually calls for was unreachable from play at all.
    assert offered(html) == []
    assert html =~ "Not written yet"
    assert html =~ ~s(phx-click="write_in" phx-value-id="#{stub.id}")
    refute html =~ "Everyone this campaign has written is already here."
  end

  test "the picker is scoped to the campaign, not the library", %{conn: conn, user: user} do
    wren = character(user, "Wren")
    stranger = character(user, "Somebody else's person")
    camp = campaign(user, [wren.id])
    id = scene(camp.id, [wren])

    {:ok, view, _html} = live(conn, ~p"/play/#{id}")
    html = view |> element("button[phx-click=toggle_cast]") |> render_click()

    # §2.7: a character belongs to one story, so this scene's picker must not offer
    # people from another campaign just because the same author owns them.
    refute to_string(stranger.id) in offered(html)
  end

  test "somebody not on offer can't be smuggled in by id", %{conn: conn, user: user} do
    wren = character(user, "Wren")
    stranger = character(user, "Outsider")
    camp = campaign(user, [wren.id])
    id = scene(camp.id, [wren])

    {:ok, view, _html} = live(conn, ~p"/play/#{id}")
    view |> element("button[phx-click=toggle_cast]") |> render_click()
    render_click(view, "add_to_scene", %{"id" => to_string(stranger.id)})

    refute to_string(stranger.id) in members(id)
    assert render(view) =~ "They aren&#39;t available to bring in."
  end

  describe "writing a walk-on in from the cast menu" do
    test "generates them, then walks them on at this beat", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      stub = character(user, "The bellman", :stub)
      camp = campaign(user, [wren.id, stub.id])
      id = scene(camp.id, [wren])

      {:ok, view, _html} = live(conn, ~p"/play/#{id}")
      view |> element("button[phx-click=toggle_cast]") |> render_click()

      view
      |> element(~s(button[phx-click="write_in"][phx-value-id="#{stub.id}"]))
      |> render_click()

      generate(view)

      # Written first — `SceneControl` refuses anything that isn't `:full`, so the
      # order is the point rather than an implementation detail.
      assert %CharacterSheet{status: :full} = Library.payload(Library.get(stub.id))
      assert to_string(stub.id) in members(id)
    end

    test "and they stop being on offer, because they are the roster now",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      stub = character(user, "The bellman", :stub)
      camp = campaign(user, [wren.id, stub.id])
      id = scene(camp.id, [wren])

      {:ok, view, _html} = live(conn, ~p"/play/#{id}")
      view |> element("button[phx-click=toggle_cast]") |> render_click()

      view
      |> element(~s(button[phx-click="write_in"][phx-value-id="#{stub.id}"]))
      |> render_click()

      html = generate(view)
      refute html =~ ~s(phx-click="write_in" phx-value-id="#{stub.id}")
    end

    test "somebody who isn't waiting to be written can't be smuggled through it",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      outsider = character(user, "Outsider", :stub)
      camp = campaign(user, [wren.id])
      id = scene(camp.id, [wren])

      {:ok, view, _html} = live(conn, ~p"/play/#{id}")
      view |> element("button[phx-click=toggle_cast]") |> render_click()
      render_click(view, "write_in", %{"id" => to_string(outsider.id)})

      # Scoped to this campaign like the picker above it (§2.7), and refused rather
      # than trusted — a `phx-click` is a message, not a button.
      refute to_string(outsider.id) in members(id)
      assert %CharacterSheet{status: :stub} = Library.payload(Library.get(outsider.id))
    end

    test "a generation that comes back unusable does not walk them on",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      stub = character(user, "The bellman", :stub)
      camp = campaign(user, [wren.id, stub.id])
      id = scene(camp.id, [wren])

      # The provider answers, and answers with nothing worth keeping. `StubGen` leaves
      # the sheet a stub, so the ok-tuple is not on its own evidence that anybody is
      # ready to be in a scene.
      Application.put_env(:polyphony, :llm,
        provider: Polyphony.LLM.Stub,
        stub_response: {:ok, "{}"}
      )

      {:ok, view, _html} = live(conn, ~p"/play/#{id}")
      view |> element("button[phx-click=toggle_cast]") |> render_click()

      view
      |> element(~s(button[phx-click="write_in"][phx-value-id="#{stub.id}"]))
      |> render_click()

      generate(view)

      refute to_string(stub.id) in members(id)
    end
  end
end
