defmodule PolyphonyWeb.ArcReviewLiveTest do
  @moduledoc """
  Arc review: character, world and group proposals, with accept / reject / edit.

  The screen sorts proposals into a tab per subject, so a test that wants to see one
  navigates to its tab first — which is also the design's own claim, that reviewing is
  per-person work rather than one flat queue.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Repo}
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, ArcEntry, WorldArcEntry}
  alias Polyphony.ReadModels.ArcEntry, as: ArcRM

  setup :register_and_log_in_user

  # Returns {campaign_entry, character_id}. Character arc is keyed by the character's
  # **library id** — the same identity the cast enters a scene under (§5.2) — so the
  # cast list and the arc rows agree without any name resolution in between.
  defp campaign(user) do
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

  defp char_proposal(character_id, statement),
    do:
      ArcRM.put(
        Repo,
        %ArcEntry{kind: :discovery, statement: statement, status: :proposed},
        character_id
      )

  defp world_proposal(camp, statement, scope, opts \\ []),
    do:
      ArcRM.put_world(
        Repo,
        %WorldArcEntry{
          kind: :discovery,
          scope: scope,
          statement: statement,
          status: :proposed,
          concealed: Keyword.get(opts, :concealed, false)
        },
        camp.id
      )

  test "shows character and world proposals side by side", %{conn: conn, user: user} do
    {camp, mira_id} = campaign(user)
    char_proposal(mira_id, "Mira has learned the truth.")
    world_proposal(camp, "The harbour is blockaded.", :local)

    # Opens on the first subject with something waiting — the reason you came here.
    {:ok, view, html} = live(conn, ~p"/arc/#{camp.id}")
    assert html =~ "Mira has learned the truth."
    assert html =~ "Mira"

    {:ok, _view, world} = live(conn, ~p"/arc/#{camp.id}?tab=world")
    assert world =~ "The harbour is blockaded."
    # A local fact says so on its own card rather than in a legend.
    assert world =~ "Known here first"
    # And a world fact says who comes to know it, which a character's never has to.
    assert world =~ "Who knows"

    # Both tabs are present, each with its count.
    assert render(view) =~ "Camp"
  end

  test "every proposal shows why, which is what makes accepting quick",
       %{conn: conn, user: user} do
    {camp, mira_id} = campaign(user)

    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :discovery,
        statement: "She has stopped signing in her mother's hand.",
        reason: "She caught herself doing it in front of Ilias.",
        status: :proposed
      },
      mira_id
    )

    {:ok, _view, html} = live(conn, ~p"/arc/#{camp.id}")

    assert html =~ "Because"
    assert html =~ "She caught herself doing it in front of Ilias."
  end

  test "a revision shows what it changes from", %{conn: conn, user: user} do
    mira =
      Library.put(%{
        owner: Owner.of(user),
        kind: "character",
        payload: %CharacterSheet{
          name: "Mira",
          temperament: "Steady to the point of being unnerving.",
          status: :full
        }
      })

    camp =
      Library.put(%{
        owner: Owner.of(user),
        kind: "campaign",
        payload: %{kind: :campaign, name: "Camp", character_ids: [mira.id], scenes: []}
      })

    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :revision,
        sheet_field: "temperament",
        statement: "Steady in the way of someone holding a door shut.",
        status: :proposed
      },
      to_string(mira.id)
    )

    {:ok, _view, html} = live(conn, ~p"/arc/#{camp.id}")

    # A replacement you can't compare is one you have to take on trust.
    assert html =~ "Steady to the point of being unnerving."
    assert html =~ ~s(class="text-[12.5px] leading-relaxed dim was mb-2")
    assert html =~ "Temperament, revised"
  end

  test "a line that gave reads as one, and offers Not yet rather than No",
       %{conn: conn, user: user} do
    {camp, mira_id} = campaign(user)

    ArcRM.put(
      Repo,
      %ArcEntry{
        kind: :release,
        released_topic: "Cover for her father",
        statement: "It broke.",
        status: :proposed
      },
      mira_id
    )

    {:ok, _view, html} = live(conn, ~p"/arc/#{camp.id}")

    assert html =~ "A line gave"
    assert html =~ "Cover for her father — it broke."
    # "No" would read as rejecting the fiction; the line simply hasn't given yet.
    assert html =~ "Not yet"
  end

  test "accepting promotes to canon; rejecting retracts", %{conn: conn, user: user} do
    {camp, mira_id} = campaign(user)
    keep = char_proposal(mira_id, "Keep this one.")
    # Concealed, so it takes the ordinary True / Edit / No — a fact proposed as
    # common knowledge has no reject at all (STR-62), only a narrowing.
    drop = world_proposal(camp, "Drop this one.", :global, concealed: true)

    {:ok, view, _html} = live(conn, ~p"/arc/#{camp.id}")
    view |> element("button[phx-value-id='#{keep.id}'][phx-click='accept']") |> render_click()
    assert Repo.get!(ArcRM, keep.id).status == "canon"
    refute render(view) =~ "Keep this one."

    {:ok, world_view, _} = live(conn, ~p"/arc/#{camp.id}?tab=world")

    world_view
    |> element("button[phx-value-id='#{drop.id}'][phx-click='reject']")
    |> render_click()

    assert Repo.get!(ArcRM, drop.id).status == "retracted"
    refute render(world_view) =~ "Drop this one."
  end

  test "a fact proposed as everyone's narrows rather than rejects (STR-62)", %{
    conn: conn,
    user: user
  } do
    {camp, _mira_id} = campaign(user)
    fact = world_proposal(camp, "The bell rang twice.", :global)

    {:ok, view, html} = live(conn, ~p"/arc/#{camp.id}?tab=world")

    # No reject and no edit on a common-knowledge card — the thing is true either
    # way and the question is who it reached.
    refute has_element?(view, "button[phx-value-id='#{fact.id}'][phx-click='reject']")
    refute has_element?(view, "button[phx-value-id='#{fact.id}'][phx-click='edit']")
    assert html =~ "Only who was there"

    view
    |> element("button[phx-value-id='#{fact.id}'][phx-click='accept_narrowed']")
    |> render_click()

    row = Repo.get!(ArcRM, fact.id)
    assert row.status == "canon"
    assert row.concealed == true
    assert %Polyphony.Authoring.Audience{scene: true} = PolyphonyCore.Blob.decode(row.audience)
  end

  test "accept all promotes every proposal at once (the §3.0 fast path)", %{
    conn: conn,
    user: user
  } do
    {camp, mira_id} = campaign(user)
    a = char_proposal(mira_id, "Character thing.")
    b = world_proposal(camp, "World thing.", :global)

    {:ok, view, _html} = live(conn, ~p"/arc/#{camp.id}")
    # Per subject: the fast path clears the tab you're on, which is the scope the
    # gate cares about.
    view |> element("button[phx-click=accept_all]") |> render_click()
    assert Repo.get!(ArcRM, a.id).status == "canon"

    {:ok, world_view, _} = live(conn, ~p"/arc/#{camp.id}?tab=world")
    world_view |> element("button[phx-click=accept_all]") |> render_click()
    assert Repo.get!(ArcRM, b.id).status == "canon"
  end

  test "editing corrects a world proposal's wording and scope before review", %{
    conn: conn,
    user: user
  } do
    {camp, _mira_id} = campaign(user)
    # Concealed, so the card carries Edit — a common-knowledge card doesn't (STR-62).
    p = world_proposal(camp, "vaeg statement", :global, concealed: true)

    {:ok, view, _html} = live(conn, ~p"/arc/#{camp.id}?tab=world")

    view |> element("button[phx-click=edit][phx-value-id='#{p.id}']") |> render_click()

    view
    |> form("form[phx-submit='save_edit']", %{
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

  describe "a group's fan-out" do
    test "collapses to one card with one fast path, and expands to per-member dissent",
         %{conn: conn, user: user} do
      owner = Owner.of(user)

      sable =
        Library.put(%{owner: owner, kind: "character", payload: %CharacterSheet{name: "Sable"}})

      bellman =
        Library.put(%{
          owner: owner,
          kind: "character",
          payload: %CharacterSheet{name: "The bellman"}
        })

      group =
        Polyphony.Groups.create(owner, %Polyphony.Authoring.Group{
          name: "The Tidewatch",
          campaign_id: "camp"
        })

      {:ok, _} = Polyphony.Groups.add_member(group.id, sable.id)
      {:ok, _} = Polyphony.Groups.add_member(group.id, bellman.id)

      camp =
        Library.put(%{
          owner: owner,
          kind: "campaign",
          payload: %{
            kind: :campaign,
            name: "Camp",
            character_ids: [sable.id, bellman.id],
            scenes: []
          }
        })

      Polyphony.Authoring.GroupArc.fan_out(group.id, %ArcEntry{
        kind: :discovery,
        statement: "They have started meeting in daylight."
      })

      {:ok, view, html} = live(conn, ~p"/arc/#{camp.id}")

      # One card, counted — a group of twelve would otherwise flood the queue.
      assert html =~ "The Tidewatch"
      assert html =~ "1 change to the group · 2 to its people"
      assert html =~ "True for all 3"
      # Expandable, with each member named.
      assert html =~ "Everyone in it changed too"
      assert html =~ "Sable"
      assert html =~ "The bellman"

      view |> element("button[phx-click=accept_group]") |> render_click()

      assert Polyphony.Authoring.GroupArc.counts(group.id) == %{group: 0, members: 0}
    end
  end
end
