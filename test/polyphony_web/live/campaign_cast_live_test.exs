defmodule PolyphonyWeb.CampaignCastLiveTest do
  @moduledoc "Managing a campaign's cast from the campaign overview (add/remove, world-scoped)."
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.Authoring.{CharacterSheet, WorldBible}
  alias Polyphony.Authoring.CharacterSheet.Relationship

  setup :register_and_log_in_user

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  defp campaign(user, attrs) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  test "a blank campaign is named where it is pitched", %{conn: conn, user: user} do
    camp = campaign(user, %{name: ""})

    # The title lives with the premise, not in Settings. It was filed with the content
    # switches and the model pickers — but a title isn't configuration, it's the first
    # line of the pitch, written in the same sitting out of the same material.
    {:ok, settings_view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")
    assert html =~ "Untitled campaign"
    refute has_element?(settings_view, "#campaign-name")

    {:ok, view, _} = live(conn, ~p"/campaigns/#{camp.id}?tab=premise")
    view |> form("#campaign-premise", %{name: "The Long Con"}) |> render_change()

    assert Library.payload(Library.get(camp.id))[:name] == "The Long Con"

    # Both fields are on the one form now, and a key that isn't submitted is still left
    # alone — the screen used to write every field on every change, which blanked the
    # name each time the premise moved.
    view |> form("#campaign-premise", %{premise: "a heist"}) |> render_change()

    payload = Library.payload(Library.get(camp.id))
    assert payload[:premise] == "a heist"
    assert payload[:name] == "The Long Con"
  end

  test "a character is added to and removed from the cast by id, not name",
       %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    camp = campaign(user, %{})

    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
    assert html =~ "Nobody is in this story yet."

    view |> form("form[phx-submit=add_character]", %{id: to_string(mira.id)}) |> render_submit()

    # Stored as the stable id, not the name.
    assert Library.payload(Library.get(camp.id))[:character_ids] == [mira.id]
    assert render(view) =~ "Mira"

    view
    |> element("button[phx-click=remove_character][phx-value-id='#{mira.id}']")
    |> render_click()

    assert Library.payload(Library.get(camp.id))[:character_ids] == []
  end

  test "a renamed character stays in the cast (referenced by id)", %{conn: conn, user: user} do
    mira = character(user, %CharacterSheet{name: "Mira", status: :full})
    camp = campaign(user, %{character_ids: [mira.id]})

    # Rename the character after casting.
    Library.update_payload(mira.id, %CharacterSheet{name: "Mirabel", status: :full})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
    # Still cast, now shown under the new name.
    assert html =~ "Mirabel"
  end

  test "the add picker is scoped to the campaign's world (plus unassigned)",
       %{conn: conn, user: user} do
    bay =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Neon Bay"}
      })

    dune =
      Library.put(%{
        owner: Owner.of(user),
        kind: "world_bible",
        payload: %WorldBible{name: "Red Dune"}
      })

    bay_char =
      character(user, %CharacterSheet{name: "BayNative", world_bible_id: bay.id, status: :full})

    dune_char =
      character(user, %CharacterSheet{name: "DuneNomad", world_bible_id: dune.id, status: :full})

    free = character(user, %CharacterSheet{name: "FreeAgent", status: :full})

    camp = campaign(user, %{bible_id: bay.id})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

    # Bay's own character and the unassigned one are offered (by id); the other world's isn't.
    assert html =~ ~s(<option value="#{bay_char.id}")
    assert html =~ ~s(<option value="#{free.id}")
    refute html =~ ~s(<option value="#{dune_char.id}")
  end

  test "the cast keeps the campaign's own order, not the library's",
       %{conn: conn, user: user} do
    # Voice colours are assigned by cast order and must be stable — the same
    # character is the same hue here, in the transcript and in the status strip. If
    # this read from the library query instead, creating an unrelated character
    # could reshuffle everyone's colour.
    a = character(user, %CharacterSheet{name: "Zeno", status: :full})
    b = character(user, %CharacterSheet{name: "Alma", status: :full})
    camp = campaign(user, %{character_ids: [a.id, b.id]})

    {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

    assert :binary.match(html, "Zeno") < :binary.match(html, "Alma")
  end

  describe "removing somebody cuts the ties" do
    test "both ways, and only within this campaign", %{conn: conn, user: user} do
      wren = character(user, %CharacterSheet{name: "Wren", status: :full})
      bram = character(user, %CharacterSheet{name: "Bram", status: :full})
      outsider = character(user, %CharacterSheet{name: "Ilias", status: :full})

      # Wren regards both; Bram regards Wren back.
      Library.update_payload(wren.id, %CharacterSheet{
        name: "Wren",
        status: :full,
        relationships: [
          %Relationship{target: "Bram", target_id: bram.id, descriptor: "owes him"},
          %Relationship{target: "Ilias", target_id: outsider.id, descriptor: "avoids him"}
        ]
      })

      Library.update_payload(bram.id, %CharacterSheet{
        name: "Bram",
        status: :full,
        relationships: [
          %Relationship{target: "Wren", target_id: wren.id, descriptor: "trusts her"}
        ]
      })

      camp = campaign(user, %{character_ids: [wren.id, bram.id]})
      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      view
      |> element(~s(button[phx-click="remove_character"][phx-value-id="#{wren.id}"]))
      |> render_click()

      # The cast forgets the leaver. Leaving the link behind means Bram's sheet — and
      # Bram's prompt, since `Context` renders relationships — keeps describing somebody
      # nobody in this story can meet.
      assert Library.payload(Library.get(bram.id)).relationships == []

      # And the leaver forgets the cast. Neither half of a link survives one of them
      # leaving.
      wren_rels = Library.payload(Library.get(wren.id)).relationships
      refute Enum.any?(wren_rels, &(&1.target_id == bram.id))

      # But not the tie to somebody outside it — that was never this campaign's to cut.
      assert Enum.any?(wren_rels, &(&1.target_id == outsider.id))
    end

    test "including a link written before ids were resolved", %{conn: conn, user: user} do
      wren = character(user, %CharacterSheet{name: "Wren", status: :full})

      bram =
        character(user, %CharacterSheet{
          name: "Bram",
          status: :full,
          # No `target_id` — the shape a relationship has before a save resolves it.
          relationships: [%Relationship{target: "wren", descriptor: "trusts her"}]
        })

      camp = campaign(user, %{character_ids: [wren.id, bram.id]})
      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      view
      |> element(~s(button[phx-click="remove_character"][phx-value-id="#{wren.id}"]))
      |> render_click()

      # A name-only link is the kind that would otherwise dangle invisibly.
      assert Library.payload(Library.get(bram.id)).relationships == []
    end

    test "and the roster still loses them", %{conn: conn, user: user} do
      wren = character(user, %CharacterSheet{name: "Wren", status: :full})
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      view
      |> element(~s(button[phx-click="remove_character"][phx-value-id="#{wren.id}"]))
      |> render_click()

      assert Library.payload(Library.get(camp.id))[:character_ids] == []
      # Removed from the story, not deleted — they are still in the library.
      assert Library.live?(Library.get(wren.id))
    end
  end

  describe "everyone invented for a story joins it" do
    test "a stub written from a relationship joins the author's campaign",
         %{conn: conn, user: user} do
      wren = character(user, %CharacterSheet{name: "Wren", status: :full})
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")

      view
      |> element(~s(button[phx-click="panel"][phx-value-panel="relationship"]))
      |> render_click()

      view
      |> form("form[phx-submit=add_relationship]", %{
        target: "The bellman",
        descriptor: "owes her"
      })
      |> render_submit()

      view |> form("#sheet-form", %{name: "Wren"}) |> render_submit()

      # A person written out of somebody's relationship belongs to that somebody's
      # story. Landing in the library alone made them invisible to the roster, to
      # "fill them in", and to the library's own grouping by campaign.
      ids = Library.payload(Library.get(camp.id))[:character_ids]
      assert length(ids) == 2

      stub = Enum.find(ids, &(&1 != wren.id))
      assert Library.payload(Library.get(stub)).name == "The bellman"
      assert Library.payload(Library.get(stub)).status == :stub
    end

    test "and appears under walk-ons rather than beside the cast",
         %{conn: conn, user: user} do
      wren = character(user, %CharacterSheet{name: "Wren", status: :full})
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/authoring/character/#{wren.id}")

      view
      |> element(~s(button[phx-click="panel"][phx-value-panel="relationship"]))
      |> render_click()

      view
      |> form("form[phx-submit=add_relationship]", %{
        target: "The bellman",
        descriptor: "owes her"
      })
      |> render_submit()

      view |> form("#sheet-form", %{name: "Wren"}) |> render_submit()

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
      assert html =~ "Walk-ons · 1"
    end
  end

  describe "walk-ons on the cast tab" do
    test "collapse behind a count instead of burying the people you came for",
         %{conn: conn, user: user} do
      lead = character(user, %CharacterSheet{name: "Wren", status: :full, tier: :main})

      walk_ons =
        for n <- ~w(Bellman Ferryman Clerk),
            do: character(user, %CharacterSheet{name: n, status: :stub, tier: :incidental})

      camp = campaign(user, %{character_ids: [lead.id | Enum.map(walk_ons, & &1.id)]})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      # `ux/polyphony-campaign.html` §06: "Main cast reads as the short list you authored;
      # walk-ons collapse behind a count." A quick-built campaign arrives with the people
      # you asked for and a dozen its cast introduced.
      assert html =~ "Cast · 4"
      assert html =~ "Walk-ons · 3"
      assert html =~ "Only remembered in their own scenes"

      # Tier is the split, not status — the count is still everyone.
      assert :binary.match(html, "Wren") < :binary.match(html, "Walk-ons")
    end

    test "a cast with no walk-ons shows no collapse at all", %{conn: conn, user: user} do
      lead = character(user, %CharacterSheet{name: "Wren", status: :full, tier: :main})
      camp = campaign(user, %{character_ids: [lead.id]})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      refute html =~ "Walk-ons ·"
    end
  end

  describe "writing one, rather than adding one that exists" do
    test "an empty cast offers a way in — it had none", %{conn: conn, user: user} do
      camp = campaign(user, %{})

      {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      # The gap: everything under Cast could *add* someone who already existed, and the
      # picker that does it is hidden when there's nobody to pick. On a first-run
      # campaign that left no route into the character editor at all, so Quick Build was
      # the only way to get a cast.
      assert html =~ "Nobody is in this story yet."

      assert {:error, {:live_redirect, %{to: "/authoring/character/" <> id}}} =
               view
               |> element(~s(button[phx-click="new_character"]), "Write a character")
               |> render_click()

      sheet = Library.payload(Library.get(id))
      assert sheet.name == "New character"

      # Cast on the way out: the button is *in* the cast list, so anything else writes
      # a character into a campaign that doesn't have them.
      assert String.to_integer(id) in Library.payload(Library.get(camp.id))[:character_ids]
    end

    test "they start as a stub, so a blank sheet can't walk into a scene",
         %{conn: conn, user: user} do
      camp = campaign(user, %{})
      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      assert {:error, {:live_redirect, %{to: "/authoring/character/" <> id}}} =
               view
               |> element(~s(button[phx-click="new_character"]), "Write a character")
               |> render_click()

      # `:stub` is not a claim about how much they matter — that's `tier`, a separate
      # axis. It's what `SceneControl` refuses, and the editor lifts it on the first
      # save (§B8), so an abandoned one reads as pending rather than as a cast member
      # with nothing written.
      assert Library.payload(Library.get(id)).status == :stub

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")
      assert html =~ "Pending"
    end

    test "they inherit the campaign's world, like every other route in",
         %{conn: conn, user: user} do
      bible =
        Library.put(%{
          owner: Owner.of(user),
          kind: "world_bible",
          payload: %WorldBible{name: "Saltmarch"}
        })

      camp = campaign(user, %{bible_id: bible.id})
      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

      assert {:error, {:live_redirect, %{to: "/authoring/character/" <> id}}} =
               view
               |> element(~s(button[phx-click="new_character"]), "Write a character")
               |> render_click()

      assert Library.payload(Library.get(id)).world_bible_id == bible.id
    end
  end
end
