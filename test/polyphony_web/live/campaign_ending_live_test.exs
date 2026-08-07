defmodule PolyphonyWeb.CampaignEndingLiveTest do
  @moduledoc """
  The three ways a campaign ends, on the screen you are on when you decide.

  They are genuinely different acts rather than one control with a severity dial —
  filing something away, throwing it out, and starting the same story over — so they are
  three controls with the copy that tells them apart. Two of them existed only in the
  library's row menu, and **restart existed nowhere**: `SceneReset` is a deployment-level
  clean slate that wipes every campaign in the database, which is not a thing an author
  can be handed.

  What restart lets go of is the part worth pinning: the scenes **and the arc queue**.
  An arc proposal is a question play raised about a character, and one that outlives the
  scene that raised it is a review item nobody can answer. The cast, the world and the
  premise are authored work and survive — that asymmetry is the whole design of it.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{App, Campaigns, Library}
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Commands.{EnterCharacter, OpenScene}
  alias Polyphony.Authoring.ArcEntry, as: ArcProposal
  alias Polyphony.ReadModels.{ArcEntry, Membership}
  alias Polyphony.Repo

  setup :register_and_log_in_user

  defp character(user, name) do
    Library.put(%{
      owner: Owner.of(user),
      kind: "character",
      payload: %CharacterSheet{name: name, status: :full}
    })
  end

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "The Salt Line", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  # A campaign with a scene actually played in it: a stream, a member interval, and an
  # arc proposal pointing back at the scene that raised it.
  defp played(user) do
    wren = character(user, "Wren")
    scene = "end-" <> Integer.to_string(System.unique_integer([:positive]))
    camp = campaign(user, %{character_ids: [wren.id], scenes: [scene]})

    :ok = App.dispatch(%OpenScene{scene_id: scene, opened_beat: 0, campaign_id: camp.id})

    :ok =
      App.dispatch(%EnterCharacter{scene_id: scene, character_id: to_string(wren.id), beat: 1})

    Membership.enter(Repo, scene, to_string(wren.id), 1)

    ArcEntry.put(
      Repo,
      %ArcProposal{
        kind: :fact,
        statement: "She burned the second page.",
        beat: 1,
        source_scene_id: scene
      },
      to_string(wren.id)
    )

    %{camp: camp, scene: scene, wren: wren}
  end

  describe "restart" do
    test "lets go of the scenes and the arc queue, and keeps everyone", %{conn: conn, user: user} do
      %{camp: camp, scene: scene, wren: wren} = played(user)

      assert ArcEntry.list_proposed(Repo, to_string(wren.id)) != []

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")
      html = view |> element("button[phx-click=restart_campaign]") |> render_click()

      payload = Library.payload(Library.get(camp.id))
      assert payload[:scenes] == []

      # The arc proposal goes with the scene that raised it. Left behind it is a
      # question about something that never happened.
      assert ArcEntry.list_proposed(Repo, to_string(wren.id)) == []
      assert Membership.members_at(Repo, scene, 1) == []

      # And the authored work is untouched — that asymmetry is the whole design.
      assert payload[:character_ids] == [wren.id]
      assert Library.get(wren.id)
      assert html =~ "Back to the start"
    end

    test "a finished campaign restarts as unstarted", %{conn: conn, user: user} do
      %{camp: camp} = played(user)
      {:ok, _} = Campaigns.finish(camp.id)

      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")
      view |> element("button[phx-click=restart_campaign]") |> render_click()

      # Concluding it was a statement about a story that is now being started again.
      assert Campaigns.status(Library.payload(Library.get(camp.id))) == :unstarted
    end

    test "it confirms, because it is the one here that can't be undone",
         %{conn: conn, user: user} do
      %{camp: camp} = played(user)

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")

      assert html =~ "Start The Salt Line over?"
      assert html =~ "can&#39;t be undone"
      # Archive and trash are both reversible, so neither asks.
      refute html =~ ~s(phx-click="archive_campaign" data-confirm)
    end

    test "with nothing played it is inert rather than absent", %{conn: conn, user: user} do
      camp = campaign(user)

      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")

      # `.btn-off` is the kit's inert treatment — a control that reads as unavailable
      # rather than one that vanishes and leaves you wondering where it went.
      assert html =~ ~r/class="btn btn-off[^"]*"[^>]*disabled/
      assert html =~ "nothing yet"
    end

    test "somebody else's campaign is not one you can wipe the play out of",
         %{user: user} do
      %{camp: camp} = played(user)
      {:ok, _} = Library.set_visibility(camp.id, :public)

      # Public means readable, not editable. The screen refuses a non-owner at mount —
      # `Permissions.can_edit?`, the same gate the editors use — so these controls are
      # never on a page somebody else is looking at. The event handlers check it a
      # second time anyway: a `phx-click` is a message, not a button.
      other = build_conn() |> log_in_user(user_fixture())

      assert {:error, {:redirect, %{to: "/browse"}}} =
               live(other, ~p"/campaigns/#{camp.id}?tab=settings")

      assert Library.payload(Library.get(camp.id))[:scenes] != []
    end
  end

  describe "archive and trash" do
    test "archive files it and lands you on the shelf", %{conn: conn, user: user} do
      camp = campaign(user)
      {:ok, view, _html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("button[phx-click=archive_campaign]") |> render_click()

      assert to == "/library?tab=shelves"
      assert [%{id: id}] = Library.archived(Owner.of(user))
      assert id == camp.id
    end

    test "trash is soft, and says so instead of confirming", %{conn: conn, user: user} do
      camp = campaign(user)
      {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")

      # No confirmation on purpose: it is on a clock, and the irreversible button lives
      # on the trash shelf where the countdown is visible.
      assert html =~ "Recoverable until it expires."

      assert {:error, {:live_redirect, _}} =
               view |> element("button[phx-click=trash_campaign]") |> render_click()

      assert [%{id: id}] = Library.trash(Owner.of(user))
      assert id == camp.id
    end
  end

  describe "the settings tab" do
    test "is flat — nothing on it is folded away", %{conn: conn, user: user} do
      camp = campaign(user)
      {:ok, _view, html} = live(conn, ~p"/campaigns/#{camp.id}?tab=settings")

      # Model tuning sat behind a `<details>`. A settings page is read by scrolling it,
      # and a fold hides one of its sections behind a guess about whether you want it —
      # a guess that is wrong the moment you came here to change that section.
      #
      # The header's `☰` is a `<details>` too, and is not a fold in the settings — so
      # the question is what the *panel* contains, not what the document does.
      panel = String.replace(html, ~r|<details class="relative.*?</details>|s, "")

      refute panel =~ "<details"
      assert html =~ "Model tuning"
      assert html =~ ~s(id="campaign-tuning")
      # The thing the fold hid, on the page rather than one click behind it.
      assert html =~ "Director reasoning"
    end
  end
end
