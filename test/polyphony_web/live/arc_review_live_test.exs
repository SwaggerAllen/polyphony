defmodule PolyphonyWeb.ArcReviewLiveTest do
  @moduledoc "Arc review (V5, §2.8): character + world proposals, with accept / reject / edit."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner, Repo}
  alias Polyphony.Authoring.{CharacterSheet, ArcEntry, WorldArcEntry}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup :register_and_log_in_user

  defp campaign(user) do
    # The cast stores library ids; character arc is keyed by the character's name.
    mira =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{name: "Mira", status: :full}
      })

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
  end

  defp char_proposal(statement),
    do:
      ArcRM.put(
        Repo,
        %ArcEntry{kind: :discovery, statement: statement, status: :proposed},
        "Mira"
      )

  defp world_proposal(camp, statement, scope),
    do:
      ArcRM.put_world(
        Repo,
        %WorldArcEntry{kind: :discovery, scope: scope, statement: statement, status: :proposed},
        camp.id
      )

  test "shows character and world proposals side by side", %{conn: conn, user: user} do
    camp = campaign(user)
    char_proposal("Mira has learned the truth.")
    world_proposal(camp, "The harbour is blockaded.", :local)

    {:ok, _view, html} = live(conn, ~p"/arc/#{camp.id}")

    assert html =~ "Characters"
    assert html =~ "Mira has learned the truth."
    assert html =~ "World"
    assert html =~ "The harbour is blockaded."
    assert html =~ "local"
  end

  test "accepting promotes to canon; rejecting retracts", %{conn: conn, user: user} do
    camp = campaign(user)
    keep = char_proposal("Keep this one.")
    drop = world_proposal(camp, "Drop this one.", :global)

    {:ok, view, _html} = live(conn, ~p"/arc/#{camp.id}")

    view |> element("button[phx-value-id='#{keep.id}'][phx-click='accept']") |> render_click()
    view |> element("button[phx-value-id='#{drop.id}'][phx-click='reject']") |> render_click()

    assert Repo.get!(ArcRM, keep.id).status == "canon"
    assert Repo.get!(ArcRM, drop.id).status == "retracted"

    # Both leave the proposed queue.
    html = render(view)
    refute html =~ "Keep this one."
    refute html =~ "Drop this one."
  end

  test "accept all promotes every proposal at once (the §3.0 fast path)", %{
    conn: conn,
    user: user
  } do
    camp = campaign(user)
    a = char_proposal("Character thing.")
    b = world_proposal(camp, "World thing.", :global)

    {:ok, view, _html} = live(conn, ~p"/arc/#{camp.id}")
    view |> element("button", "Accept all") |> render_click()

    assert Repo.get!(ArcRM, a.id).status == "canon"
    assert Repo.get!(ArcRM, b.id).status == "canon"
  end

  test "editing corrects a world proposal's wording and scope before review", %{
    conn: conn,
    user: user
  } do
    camp = campaign(user)
    p = world_proposal(camp, "vaeg statement", :global)

    {:ok, view, _html} = live(conn, ~p"/arc/#{camp.id}")

    view
    |> form("form[phx-submit='edit']", %{
      entry_id: p.id,
      statement: "A clear statement.",
      scope: "local"
    })
    |> render_submit()

    row = Repo.get!(ArcRM, p.id)
    assert row.statement == "A clear statement."
    assert row.scope == "local"
    assert row.status == "proposed"
  end
end
