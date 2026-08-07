defmodule PolyphonyWeb.CampaignScenesLiveTest do
  @moduledoc """
  The scenes list: what a scene is **called**, and how one is thrown away.

  A scene's identity on this screen was its event-store stream id, sliced to twelve
  characters — `Scene 0f3a-91bb…`. That is not a name a person can hold, and a campaign's
  scenes list was a column of near-identical hex. The same string was also being handed to
  the model as *the scenes already played*, to steer the next one away from repeating a
  setting it had no way to identify.

  A scene is a chapter, so it is numbered by its position in the campaign and titled by
  where it happens. `SceneOpened` has carried `location_id` since §2.3 and nothing read it
  back until now.

  Deletion is `Campaigns.restart/2` scoped to one scene, and the part worth pinning is the
  same: the **arc proposals go with it**. A question play raised about a character, left
  behind after the scene that raised it is gone, is a review item nobody can answer.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Campaigns, Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.ArcEntry, as: ArcProposal
  alias Polyphony.ReadModels.{ArcEntry, Membership}
  alias PolyphonyCore.Commands.{EnterCharacter, OpenScene}

  setup :register_and_log_in_user

  defp character(user, name) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  defp campaign(user, attrs) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "The Salt Line", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  # Opens a real stream, because the location comes off `SceneOpened` rather than off
  # anything the campaign payload stores.
  defp open_scene(camp_id, opts) do
    scene = "sc-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      App.dispatch(%OpenScene{
        scene_id: scene,
        opened_beat: 0,
        campaign_id: camp_id,
        location_id: opts[:location],
        premise: opts[:premise]
      })

    scene
  end

  # `payload.scenes` is newest-first, the order the screen writes it in.
  defp with_scenes(user, scene_opts) do
    camp = campaign(user, %{})

    scenes = for opts <- scene_opts, do: open_scene(camp.id, opts)

    {:ok, _} =
      Library.update_payload(camp.id, %{camp_payload(camp) | scenes: Enum.reverse(scenes)})

    {camp, scenes}
  end

  defp camp_payload(camp), do: Library.payload(Library.get(camp.id))

  describe "what a scene is called" do
    test "its number in the campaign and where it happens", %{conn: conn, user: user} do
      {camp, [first, second]} =
        with_scenes(user, [
          [location: "The dock, before first light"],
          [location: "The quay, after the second bell"]
        ])

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      assert html =~ "Scene 1 · The dock, before first light"
      assert html =~ "Scene 2 · The quay, after the second bell"

      # The id is still the link target — it is the routing key, it just isn't the name.
      assert html =~ ~s(href="/play/#{first}")
      assert html =~ ~s(href="/play/#{second}")
      refute html =~ "Scene " <> String.slice(first, 0, 12)
    end

    test "a scene opened nowhere still has a number", %{conn: conn, user: user} do
      # `location_id` is optional on the command and blank is a real state — the author
      # can start a scene without saying where. Falling back to the id would put the hex
      # back on the screen for exactly the scenes that most need a name.
      {camp, _} = with_scenes(user, [[location: nil]])

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      assert html =~ "Scene 1 · A scene"
    end

    test "the newest is on top, so the numbers count down", %{conn: conn, user: user} do
      {camp, _} = with_scenes(user, [[location: "The dock"], [location: "The quay"]])

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      # Position, not presence: a reverse-chronological list of chapters is the point.
      assert :binary.match(html, "Scene 2 · The quay") <
               :binary.match(html, "Scene 1 · The dock")
    end
  end

  describe "deleting one" do
    setup %{user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id]})

      keep = open_scene(camp.id, location: "The dock")
      drop = open_scene(camp.id, location: "The quay")

      :ok =
        App.dispatch(%EnterCharacter{scene_id: drop, character_id: to_string(wren.id), beat: 1})

      Membership.enter(Repo, drop, to_string(wren.id), 1)

      ArcEntry.put(
        Repo,
        %ArcProposal{
          kind: :fact,
          statement: "She burned the second page.",
          beat: 1,
          source_scene_id: drop
        },
        to_string(wren.id)
      )

      {:ok, _} =
        Library.update_payload(camp.id, %{camp_payload(camp) | scenes: [drop, keep]})

      %{camp: camp, keep: keep, drop: drop, wren: wren}
    end

    test "takes the scene and everything derived from it", ctx do
      %{conn: conn, camp: camp, keep: keep, drop: drop, wren: wren} = ctx

      assert ArcEntry.list_proposed(Repo, to_string(wren.id)) != []

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      html = view |> element("button[phx-value-id='#{drop}']") |> render_click()

      assert camp_payload(camp)[:scenes] == [keep]

      # The proposal goes with the scene that raised it — the same asymmetry restart has.
      assert ArcEntry.list_proposed(Repo, to_string(wren.id)) == []
      assert Membership.members_at(Repo, drop, 1) == []

      # And the cast is authored work, so it survives its scenes.
      assert camp_payload(camp)[:character_ids] == [wren.id]
      assert Library.get(wren.id)
      assert html =~ "Scene deleted"
    end

    test "the other scene keeps its place and is renumbered", ctx do
      %{conn: conn, camp: camp, drop: drop} = ctx

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      html = view |> element("button[phx-value-id='#{drop}']") |> render_click()

      # Named specifically: the scene-location input on this tab carries "The quay, after
      # the second bell" as its placeholder, so a bare refute passes for the wrong reason.
      refute html =~ "Scene 2 · The quay"
      # Was scene 1 and still is. A number is a position, not an identifier — deleting
      # scene 1 of three has to renumber the two that remain.
      assert html =~ "Scene 1 · The dock"
    end

    test "it names what goes with it before it goes", ctx do
      %{conn: conn, camp: camp} = ctx

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")

      assert html =~ "Delete Scene 2 · The quay?"
      assert html =~ "arc proposals it raised"
      assert html =~ "can&#39;t be undone"
    end

    test "the event stream is left alone, because events are immutable", ctx do
      %{conn: conn, camp: camp, drop: drop} = ctx

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=scenes")
      view |> element("button[phx-value-id='#{drop}']") |> render_click()

      # Abandoned, not erased (rule 6). Nothing reads a stream no campaign names, and
      # rewriting history is the one thing an event-sourced system may never do.
      assert App |> Commanded.EventStore.stream_forward(drop) |> Enum.count() > 0
    end
  end

  describe "Campaigns.delete_scene/3" do
    test "refuses a scene the campaign never held", %{user: user} do
      {camp, _} = with_scenes(user, [[location: "The dock"]])

      assert {:error, :no_such_scene} = Campaigns.delete_scene(camp.id, "sc-nobody")
    end

    test "leaves finished_at alone, unlike restart", %{user: user} do
      # Deleting one scene says nothing about whether the story is over; starting the
      # whole campaign again says exactly that, which is why only restart clears it.
      {camp, [scene]} = with_scenes(user, [[location: "The dock"]])
      {:ok, _} = Campaigns.finish(camp.id)

      {:ok, _} = Campaigns.delete_scene(camp.id, scene)

      assert Campaigns.status(camp_payload(camp)) == :finished
    end
  end
end
