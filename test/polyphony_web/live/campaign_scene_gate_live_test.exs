defmodule PolyphonyWeb.CampaignSceneGateLiveTest do
  @moduledoc "The arc-review gate on starting a scene from the campaign overview (§3.0)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner, Repo}
  alias Polyphony.Authoring.{CharacterSheet, ArcEntry}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup :register_and_log_in_user

  # Returns {campaign_entry, character_id} — the gate checks pending arc by library
  # id, the same identity the cast enters a scene under (§5.2).
  defp campaign_with_ready_cast(user) do
    mira =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Mira", status: :full}
      })

    camp =
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{
          kind: :campaign,
          name: "Camp",
          character_ids: [mira.id],
          bible_id: nil,
          scenes: []
        }
      })

    {camp, to_string(mira.id)}
  end

  defp propose_arc(character_id),
    do:
      ArcRM.put(
        Repo,
        %ArcEntry{kind: :discovery, statement: "x", status: :proposed},
        character_id
      )

  test "starting a scene is blocked to arc review while a cast member has pending arc",
       %{conn: conn, user: user} do
    {camp, mira_id} = campaign_with_ready_cast(user)
    propose_arc(mira_id)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")

    assert {:error, {:redirect, %{to: path}}} =
             view |> element("button", "Start a scene") |> render_click()

    assert path == "/arc/#{camp.id}"

    # No scene was opened.
    assert Library.payload(Library.get(camp.id))[:scenes] == []
  end

  test "with no pending arc, starting a scene opens play", %{conn: conn, user: user} do
    {camp, _mira_id} = campaign_with_ready_cast(user)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")

    assert {:error, {:redirect, %{to: path}}} =
             view |> element("button", "Start a scene") |> render_click()

    assert path =~ "/play/"
    assert [<<"sc-", _::binary>>] = Library.payload(Library.get(camp.id))[:scenes]
  end

  test "accepting the pending arc unblocks the next scene", %{conn: conn, user: user} do
    {camp, _mira_id} = campaign_with_ready_cast(user)
    row = propose_arc("Mira")

    ArcRM.accept(Repo, row.id)

    {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}")

    assert {:error, {:redirect, %{to: path}}} =
             view |> element("button", "Start a scene") |> render_click()

    assert path =~ "/play/"
  end
end
