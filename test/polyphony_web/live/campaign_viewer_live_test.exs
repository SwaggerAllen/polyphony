defmodule PolyphonyWeb.CampaignViewerLiveTest do
  @moduledoc """
  The campaign hub as a place where content is *reviewed*, and the way back out of it.

  Two things it was missing. The **perspective control** — the product's spine, and the
  one `ux/README.md` singles out as the design's worst consistency failure when it
  drifts — wasn't here, even though the world tab is a read of the bible and "what does
  Wren actually know of this world" is a question you can only answer through her eyes.
  And the world read showed three of the five fields the editor has: no cover, which is
  the one part a stranger sees, and no starting canon, which is what the Director opens
  a scene from. A review of half a thing is a review of nothing.

  The other half is the chevron. It worked — it navigated to the library — but from
  inside a campaign the library is a place you passed *through*, not the place you were.
  A character belongs to one campaign (§2.7) and attaching a world copies it (§2.5b), so
  in both cases the campaign is a lookup rather than a guess.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.Authoring.{Audience, CharacterSheet, Group, WorldBible}
  alias Polyphony.Authoring.WorldBible.Entry

  setup :register_and_log_in_user

  defp character(user, name, attrs \\ %{}) do
    sheet = struct(%CharacterSheet{name: name, status: :full}, attrs)
    Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})
  end

  defp world(user, attrs) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "world_bible",
      payload: struct(%WorldBible{name: "Saltmarch"}, attrs)
    })
  end

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{
          kind: :campaign,
          name: "The Salt Line",
          character_ids: [],
          bible_id: nil,
          scenes: []
        },
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  describe "the world review surface" do
    setup %{user: user} do
      wren = character(user, "Wren")

      bible =
        world(user, %{
          cover: "A port that keeps its own books.",
          setting: "A tidal town.",
          tone: "Wet and quiet.",
          rules: [
            %Entry{statement: "The tide runs twice a day.", concealed: false},
            %Entry{statement: "The core is a sleeping thing.", concealed: true}
          ],
          starting_canon: [%Entry{statement: "The last ferry left a year ago.", concealed: false}]
        })

      camp = campaign(user, %{character_ids: [wren.id], bible_id: bible.id})
      %{camp: camp, wren: wren}
    end

    test "shows every field the editor has", %{conn: conn, camp: camp} do
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      # Cover and starting canon were both missing — the part a stranger reads, and the
      # part the Director opens a scene from.
      assert html =~ "A port that keeps its own books."
      assert html =~ "A tidal town."
      assert html =~ "Wet and quiet."
      assert html =~ "The tide runs twice a day."
      assert html =~ "The last ferry left a year ago."
    end

    test "the author is omniscient over their own world, and secrets are marked",
         %{conn: conn, camp: camp} do
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      assert html =~ "The core is a sleeping thing."
      # `:secret` — the same mark the bible editor gives it, so two screens don't
      # describe one entry two ways.
      assert html =~ ~s(class="secret)
    end

    test "through a character's eyes, what they haven't been told isn't there",
         %{conn: conn, camp: camp, wren: wren} do
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world&as=#{wren.id}")

      assert html =~ "The tide runs twice a day."
      refute html =~ "The core is a sleeping thing."

      # Said out loud: a page that silently drops three rules reads as a page missing
      # three rules.
      assert html =~ "As <b>Wren</b> knows it"
    end
  end

  describe "a secret that is not secret from everyone" do
    test "a secret whose audience names them is theirs", %{conn: conn, user: user} do
      wren = character(user, "Wren")

      bible =
        world(user, %{
          rules: [
            %Entry{
              statement: "The core is a sleeping thing.",
              concealed: true,
              audience: %Audience{character_ids: [to_string(wren.id)]}
            }
          ]
        })

      camp = campaign(user, %{character_ids: [wren.id], bible_id: bible.id})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world&as=#{wren.id}")

      # The point of a per-character read rather than a blanket public one: concealed
      # doesn't mean concealed *from everybody*.
      assert html =~ "The core is a sleeping thing."
    end

    test "a group they're in carries what it knows", %{conn: conn, user: user} do
      wren = character(user, "Wren")

      group =
        Library.put(%{
          owner: Owner.of(user),
          kind: Group.kind(),
          payload: %Group{name: "The Tidewatch", member_ids: [to_string(wren.id)]}
        })

      bible =
        world(user, %{
          rules: [
            %Entry{
              statement: "The ledger's second page is missing.",
              concealed: true,
              audience: %Audience{group_ids: [to_string(group.id)]}
            }
          ]
        })

      camp = campaign(user, %{character_ids: [wren.id], bible_id: bible.id})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world&as=#{wren.id}")

      # Groups are named, not expanded — the membership moves, and the read has to
      # resolve through it rather than through a list of names.
      assert html =~ "The ledger&#39;s second page is missing."
    end
  end

  describe "the perspective control" do
    test "offers omniscient and the castable cast, and nobody else",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      stub = character(user, "The bellman", %{status: :stub})
      camp = campaign(user, %{character_ids: [wren.id, stub.id]})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")

      assert html =~ ~s(id="campaign-viewer-select")
      assert html =~ ~s(<option value="#{wren.id}")
      # A stub has no knowledge to speak of, so its view answers every question the
      # same way. Offering it would be offering a viewpoint that says nothing.
      refute html =~ ~s(<option value="#{stub.id}")
    end

    test "switching is a patch, so the tab you were on survives it",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      camp = campaign(user, %{character_ids: [wren.id]})

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
      view |> form("#campaign-viewer", %{as: to_string(wren.id)}) |> render_change()

      assert_patched(view, "/campaigns/#{camp.id}?tab=world&as=#{wren.id}")
    end

    test "an id that isn't on this roster is refused rather than trusted",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      outsider = character(user, "Somebody else's")

      bible = world(user, %{rules: [%Entry{statement: "A secret.", concealed: true}]})
      camp = campaign(user, %{character_ids: [wren.id], bible_id: bible.id})

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world&as=#{outsider.id}")

      # This is the control that decides which secrets are on the screen, so an
      # unrecognised value falls back to the author's own view rather than to a
      # character-shaped one nobody can account for.
      refute html =~ "knows it"
      assert html =~ "A secret."
    end

    test "there is nothing to switch to before there is a cast", %{conn: conn, user: user} do
      camp = campaign(user)
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=world")
      refute html =~ ~s(id="campaign-viewer-select")
    end
  end

  describe "the way back" do
    test "a character's chevron goes to their campaign, by name",
         %{conn: conn, user: user} do
      wren = character(user, "Wren")
      campaign(user, %{character_ids: [wren.id]})

      {:ok, view, html} = live(conn, ~p"/authoring/character/#{wren.id}")

      assert html =~ ~s(aria-label="Back to The Salt Line")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element(~s(a[aria-label="Back to The Salt Line"])) |> render_click()

      assert to =~ "/campaigns/"
    end

    test "a world's chevron does too — attaching copies, so there is one campaign",
         %{conn: conn, user: user} do
      bible = world(user, %{})
      camp = campaign(user, %{bible_id: bible.id})

      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{bible.id}")
      assert html =~ ~s(href="/campaigns/#{camp.id}")
      assert html =~ "Back to The Salt Line"
    end

    test "a library template keeps the library, which is where it belongs",
         %{conn: conn, user: user} do
      bible = world(user, %{})

      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{bible.id}")
      assert html =~ ~s(aria-label="Back to library")
    end
  end
end
