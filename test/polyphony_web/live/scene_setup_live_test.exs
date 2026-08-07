defmodule PolyphonyWeb.SceneSetupLiveTest do
  @moduledoc """
  Setting a scene: who is in it, where it happens, and what is already true when it opens.

  Three things the screen couldn't say before. Every scene took the **whole ready cast**,
  which is how a two-hander becomes a crowd — and the roster is what turn order walks, so
  it is a cost as well as a shape. Every scene also opened on the **campaign** premise,
  which is the pitch for the whole story and says nothing about now. And there was no way
  to ask for either, on a screen where every other authored field has a ✦.

  The default is deliberately unchanged: an author who touches none of it gets the same
  scene they always got. A selection only exists once somebody makes one.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias PolyphonyCore.Events.SceneOpened

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp character(user, name, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name, status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp campaign(user, attrs) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  defp opened(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Enum.find(&match?(%SceneOpened{}, &1))
  end

  defp entered(scene_id) do
    App
    |> Commanded.EventStore.stream_forward(scene_id)
    |> Enum.map(& &1.data)
    |> Enum.filter(&match?(%PolyphonyCore.Events.CharacterEntered{}, &1))
    |> Enum.map(& &1.character_id)
    |> Enum.sort()
  end

  defp latest_scene(camp), do: Library.payload(Library.get(camp.id))[:scenes] |> List.first()

  describe "who's in it" do
    test "defaults to everyone ready, exactly as it always did", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      bram = character(user, "Bram")
      camp = campaign(user, %{character_ids: [wren.id, bram.id]})

      {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      assert html =~ "Who&#39;s in it"
      assert html =~ "2 of 2"

      render_click(view, "start_scene", %{})

      assert entered(latest_scene(camp)) ==
               Enum.sort([to_string(wren.id), to_string(bram.id)])
    end

    test "and only the ones picked go in", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      bram = character(user, "Bram")
      camp = campaign(user, %{character_ids: [wren.id, bram.id]})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      # The first tap materialises the set from "everyone", so turning one person off
      # doesn't read as turning everyone else off.
      html =
        view
        |> element(~s(button[phx-click="toggle_scene_cast"][phx-value-id="#{bram.id}"]))
        |> render_click()

      assert html =~ "1 of 2"

      render_click(view, "start_scene", %{})
      assert entered(latest_scene(camp)) == [to_string(wren.id)]
    end

    test "picking nobody disables the button rather than opening an empty scene",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      html =
        view
        |> element(~s(button[phx-click="toggle_scene_cast"][phx-value-id="#{wren.id}"]))
        |> render_click()

      assert html =~ "Nobody is in it. Pick at least one."
      assert html =~ ~r/<button[^>]*disabled[^>]*phx-click="start_scene"/
    end

    test "a pending stub is never offered", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      stub = character(user, "The bellman", %{status: :stub})
      camp = campaign(user, %{character_ids: [wren.id, stub.id]})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      # `SceneControl` refuses a non-`:full` character, so offering one as a chip would
      # be offering a choice that can't be honoured.
      assert html =~ "1 of 1"
      refute html =~ ~s(phx-click="toggle_scene_cast" phx-value-id="#{stub.id}")

      # It is offered as something to *write*, which is the honest version of the same
      # offer — and reachable from the screen where you are choosing a cast, rather
      # than only from a bulk pass on another tab.
      assert html =~ "Not written yet"
      assert html =~ ~s(phx-click="write_in" phx-value-id="#{stub.id}")
    end
  end

  describe "the scene's own premise" do
    test "is what the scene opens on", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id], premise: "A campaign-wide heist."})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      view
      |> form("#scene-where", %{location: "The quay", premise: "The ledger is due by dawn."})
      |> render_change()

      render_click(view, "start_scene", %{})

      assert %SceneOpened{location_id: "The quay", premise: "The ledger is due by dawn."} =
               opened(latest_scene(camp))
    end

    test "left blank, the campaign's stands in — which is what every scene used to get",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id], premise: "A campaign-wide heist."})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      render_click(view, "start_scene", %{})

      assert %SceneOpened{premise: "A campaign-wide heist."} = opened(latest_scene(camp))
    end
  end

  describe "✦ Suggest" do
    test "fills both, because they are one decision", %{conn: conn, user: user} do
      wren = character(user, "Wren")

      bible =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{name: "Saltmarch", setting: "A tidal port."}
        })

      camp = campaign(user, %{character_ids: [wren.id], bible_id: bible.id})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      view |> element("button[phx-click=suggest_scene]") |> render_click()

      html = generate(view)

      # A location is only worth choosing if it puts these people somewhere something
      # can happen, so both fields come back from one call.
      assert [_, _] = Regex.run(~r/id="scene-location"[^>]*value="([^"]+)"/, html)
      assert [_, premise] = Regex.run(~r|id="scene-premise".*?>(.*?)</textarea>|s, html)
      assert String.trim(premise) != ""
    end

    test "survives the tab being closed while it runs", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      view |> element("button[phx-click=suggest_scene]") |> render_click()

      # Same durability as every other ✦: the answer waits rather than dying with the
      # socket, and a fresh mount shows the spinner while it's still running.
      {:ok, reopened, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      assert html =~ "✦ …"

      # Every tab closes before the work lands. A socket that is still listening would
      # take the result live and consume it, which is the case the *other* test covers.
      Process.flag(:trap_exit, true)
      for v <- [view, reopened], do: GenServer.stop(v.pid, :shutdown)

      Oban.drain_queue(queue: :generation)

      # The re-delivery `restore_generations/2` does is an ordinary message, so it lands
      # a beat after mount — `render/1` is what waits for it.
      {:ok, later, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      assert render(later) =~ ~r/id="scene-location"[^>]*value="[^"]+"/
    end
  end

  describe "writing a walk-on in while choosing a cast" do
    test "writes them and puts them in the scene", %{conn: conn, user: user} do
      wren = character(user, "Wren")
      stub = character(user, "The bellman", %{status: :stub})
      camp = campaign(user, %{character_ids: [wren.id, stub.id]})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      view
      |> element(~s(button[phx-click="write_in"][phx-value-id="#{stub.id}"]))
      |> render_click()

      html = generate(view)

      # Written, and therefore castable at all.
      assert %CharacterSheet{status: :full} = Library.payload(Library.get(stub.id))

      # And selected. The only reason to press this while choosing who is in a scene is
      # to use them, so making it two steps would be making the second one pointless.
      assert html =~ "2 of 2"

      render_click(view, "start_scene", %{})
      assert to_string(stub.id) in entered(latest_scene(camp))
    end

    test "a campaign of nothing but stubs still offers the way out",
         %{conn: conn, user: user} do
      stub = character(user, "The bellman", %{status: :stub})
      camp = campaign(user, %{character_ids: [stub.id]})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      # The block used to render only when somebody was already ready, which hid the
      # one control that fixes having nobody ready.
      assert html =~ "Not written yet"
      assert html =~ ~s(phx-click="write_in" phx-value-id="#{stub.id}")
    end

    test "somebody already written isn't offered to be written again",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      refute html =~ "Not written yet"

      # And refused rather than ignored if asked for anyway.
      assert render_click(view, "write_in", %{"id" => to_string(wren.id)}) =~
               "aren&#39;t waiting to be written"
    end
  end
end
