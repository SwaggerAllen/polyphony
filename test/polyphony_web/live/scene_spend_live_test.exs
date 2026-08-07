defmodule PolyphonyWeb.SceneSpendLiveTest do
  @moduledoc """
  Where a scene's spend shows up in the cost breakdown.

  The Director loop resolved this properly all along: `Attribution.for_scene/1` reads
  the `campaign_id` off `SceneOpened` and carries it on the job's args, so a cast turn
  and the Director's own decision bill the campaign. The **play screen** did not. Every
  ✦ on it built its meter options by hand — a `user_id`, a `usage_kind`, and nothing
  else — so drafting a turn, drafting a narration, writing a walk-on in and sweeping for
  mentions all recorded `campaign_id: nil`.

  Settings groups by campaign and buckets the nils as *Writing characters and worlds ·
  Outside any scene*. So work done inside a scene appeared in the one row that means
  "not in a scene", and the campaign the money was actually spent on looked cheaper than
  it was — which is the number the per-campaign cap is set against.

  Supplying the id also puts these calls under that cap, which is where they belonged.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Costs, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias PolyphonyCore.Commands.{EnterCharacter, OpenScene}

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Stub)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp scene_in_campaign(user) do
    wren =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Wren", status: :full, premise: "She counts twice."}
      })

    camp =
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "The Salt Line",
          character_ids: [wren.id],
          bible_id: nil,
          scenes: []
        }
      })

    id = "spend-" <> Integer.to_string(System.unique_integer([:positive]))
    :ok = App.dispatch(%OpenScene{scene_id: id, opened_beat: 0, campaign_id: camp.id})
    :ok = App.dispatch(%EnterCharacter{scene_id: id, character_id: to_string(wren.id), beat: 1})

    %{scene: id, camp: camp, wren: wren}
  end

  defp drain, do: Oban.drain_queue(queue: :generation, with_recursion: true, with_scheduled: true)

  # What the settings screen would show: campaign id => amount, this month.
  defp billed(user), do: Map.new(Costs.by_campaign(user.id), &{&1.campaign_id, &1.amount})

  defp spent_on(user, camp), do: Map.get(billed(user), to_string(camp.id), 0)
  defp unattributed(user), do: Map.get(billed(user), nil, 0)

  test "a narration drafted in a scene is that campaign's spend",
       %{conn: conn, user: user} do
    %{scene: scene, camp: camp} = scene_in_campaign(user)

    {:ok, view, _} = live(conn, ~p"/play/#{scene}")
    render_click(view, "narrate_open", %{})
    render_click(view, "expand_narrate", %{})
    drain()

    assert spent_on(user, camp) > 0
    assert unattributed(user) == 0
  end

  test "so is a turn drafted with ✦ Expand", %{conn: conn, user: user} do
    %{scene: scene, camp: camp, wren: wren} = scene_in_campaign(user)

    {:ok, view, _} = live(conn, ~p"/play/#{scene}?as=#{wren.id}")
    render_click(view, "compose", %{"text" => "She looks at the ledger."})
    drain()

    assert spent_on(user, camp) > 0
    assert unattributed(user) == 0
  end

  test "and writing a walk-on into a running scene", %{conn: conn, user: user} do
    %{scene: scene, camp: camp} = scene_in_campaign(user)

    bellman =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "The bellman", status: :stub}
      })

    payload = Library.payload(Library.get(camp.id))

    Library.update_payload(camp.id, %{
      payload
      | character_ids: payload.character_ids ++ [bellman.id]
    })

    {:ok, view, _} = live(conn, ~p"/play/#{scene}")
    render_click(view, "toggle_cast", %{})
    render_click(view, "write_in", %{"id" => to_string(bellman.id)})
    drain()

    # Writing a character is authoring by *kind* — that hasn't changed, and shouldn't.
    # Which campaign paid for it is a different question, and the answer is this one.
    assert spent_on(user, camp) > 0
    assert unattributed(user) == 0
  end

  test "the row still knows the campaign after it has been filed away",
       %{conn: conn, user: user} do
    %{scene: scene, camp: camp} = scene_in_campaign(user)

    {:ok, view, _} = live(conn, ~p"/play/#{scene}")
    render_click(view, "narrate_open", %{})
    render_click(view, "expand_narrate", %{})
    drain()

    {:ok, _} = Library.archive(camp.id)
    {:ok, _view, html} = live(conn, ~p"/settings")

    # The breakdown looked the campaign up in the *listing*, which excludes archived and
    # trashed — so filing a story away moved its whole history into "outside any scene".
    # A row is where the money went; the shelf it sits on now doesn't change that.
    assert html =~ "The Salt Line"
    refute html =~ "Outside any scene"
  end
end
