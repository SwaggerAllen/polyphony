defmodule PolyphonyWeb.CampaignContentLiveTest do
  @moduledoc """
  The campaign's content/maturity ceiling (§A5, layer 2): the editor controls, and the
  end-to-end effect that starting a scene caps a character's categorized boundary closed
  unless the campaign enables that category.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.Library
  alias Polyphony.Owner
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias PolyphonyCore.Content.CampaignConfig
  alias Polyphony.Context.Store

  setup :register_and_log_in_user

  defp character(user, sheet),
    do: Library.put(%{owner: Owner.of(user), kind: "character", payload: sheet})

  defp campaign(user, attrs \\ %{}) do
    payload =
      Map.merge(
        %{kind: :campaign, name: "Camp", character_ids: [], bible_id: nil, scenes: []},
        attrs
      )

    Library.put(%{owner: Owner.of(user), kind: "campaign", payload: payload})
  end

  test "toggling the content ceiling persists a CampaignConfig", %{conn: conn, user: user} do
    camp = campaign(user)
    {:ok, view, html} = live(conn, ~p"/campaigns/#{camp.id}")

    # Sub-toggles are hidden until the adult master is on.
    refute html =~ ~s(name="sexual")

    # Turning the master on reveals the sub-toggles; then enable one.
    view |> form("#campaign-content", %{"adult_content" => "true"}) |> render_change()

    view
    |> form("#campaign-content", %{"adult_content" => "true", "sexual" => "true"})
    |> render_change()

    config = CampaignConfig.from_payload(Library.payload(Library.get(camp.id)))
    assert config.adult_content
    assert config.sexual
    refute config.graphic_violence

    # The label reflects the choice, and the sub-toggles now render.
    html = render(view)
    assert html =~ "Adult content: sexual"
    assert html =~ ~s(name="graphic_violence")
  end

  defp intimacy_char(user) do
    boundary = %Boundary{
      topic: "intimacy",
      stance: :conditional,
      condition: "trust",
      category: :sexual
    }

    character(user, %CharacterSheet{name: "Mira", status: :full, boundaries: [boundary]})
  end

  defp start_scene_id(conn, camp) do
    {:ok, view, _} = live(conn, ~p"/campaigns/#{camp.id}?tab=cast")

    {:error, {:redirect, %{to: path}}} =
      view |> element("button[phx-click=start_scene]") |> render_click()

    path |> String.split("/") |> List.last()
  end

  test "a disabled category forces the boundary closed at scene start", %{conn: conn, user: user} do
    mira = intimacy_char(user)
    # Adult content OFF (default) ⇒ empty register ⇒ the :sexual boundary is forced closed.
    camp = campaign(user, %{character_ids: [mira.id]})

    # Context is cached under the character's **library id** — the same key they
    # entered the scene under (§5.2), not their name.
    {:ok, ctx} = Store.fetch(start_scene_id(conn, camp), to_string(mira.id))
    refute ctx.prefix =~ "Content register enabled"
    assert ctx.prefix =~ "intimacy: a hard line"
  end

  test "an enabled category lets the boundary keep its stance", %{conn: conn, user: user} do
    mira = intimacy_char(user)
    # Adult + sexual enabled ⇒ the boundary keeps its conditional stance in the prefix.
    camp =
      campaign(user, %{
        character_ids: [mira.id],
        content_config: %CampaignConfig{adult_content: true, sexual: true}
      })

    {:ok, ctx} = Store.fetch(start_scene_id(conn, camp), to_string(mira.id))
    assert ctx.prefix =~ "Content register enabled"
    assert ctx.prefix =~ "intimacy: you will not — not until trust"
  end

  describe "the ceiling reaches the sheet editor (§V8a)" do
    defp blank_char(user), do: character(user, %CharacterSheet{name: "Mira", status: :full})

    # Adding to a list opens a panel below the sheet — the form doesn't exist until then.
    defp add_boundary(view, attrs) do
      view
      |> element("button[phx-click=panel][phx-value-panel=pressure]")
      |> render_click()

      view
      |> form("form[phx-submit=add_boundary]", Map.merge(%{"topic" => "intimacy"}, attrs))
      |> render_submit()
    end

    defp save(view), do: view |> form("form[phx-submit=save]", %{name: "Mira"}) |> render_submit()

    test "an open boundary the campaign forbids is saved held", %{conn: conn, user: user} do
      mira = blank_char(user)
      # Adult content off — the default — so `:sexual` is not in the register.
      _camp = campaign(user, %{character_ids: [mira.id]})

      {:ok, view, _} = live(conn, ~p"/authoring/character/#{mira.id}")

      html =
        add_boundary(view, %{
          "direction" => "compulsion",
          "stance" => "open",
          "category" => "sexual"
        })

      assert html =~ "this campaign doesn&#39;t allow explicit sexual content"

      save(view)
      [saved] = Library.payload(Library.get(mira.id)).boundaries

      # Capped toward **refusal**, not merely closed. A closed compulsion is one she
      # always acts on, so a cap that only set the stance would make the ceiling compel
      # the content it exists to forbid.
      assert %Boundary{stance: :closed, direction: :refusal, category: :sexual} = saved
    end

    test "the same boundary is untouched when the campaign allows it", %{conn: conn, user: user} do
      mira = blank_char(user)

      _camp =
        campaign(user, %{
          character_ids: [mira.id],
          content_config: %CampaignConfig{adult_content: true, sexual: true}
        })

      {:ok, view, _} = live(conn, ~p"/authoring/character/#{mira.id}")

      html =
        add_boundary(view, %{
          "direction" => "compulsion",
          "stance" => "open",
          "category" => "sexual"
        })

      # Not the bare phrase — the panel's own note already contains it, and matching that
      # would make this pass whatever the code did.
      refute html =~ "this campaign doesn&#39;t allow"

      save(view)
      [saved] = Library.payload(Library.get(mira.id)).boundaries
      assert %Boundary{stance: :open, direction: :compulsion} = saved
    end

    test "a character in no campaign has no ceiling to cap against", %{conn: conn, user: user} do
      # The all-off config means *this campaign permits nothing*, which is right for a
      # campaign and exactly wrong for a character who hasn't got one — reading it as the
      # default would cap every categorized boundary on a standalone sheet.
      mira = blank_char(user)

      {:ok, view, _} = live(conn, ~p"/authoring/character/#{mira.id}")

      add_boundary(view, %{
        "direction" => "compulsion",
        "stance" => "open",
        "category" => "sexual"
      })

      save(view)
      [saved] = Library.payload(Library.get(mira.id)).boundaries
      assert %Boundary{stance: :open, direction: :compulsion} = saved
    end

    test "an uncategorized boundary is never capped", %{conn: conn, user: user} do
      mira = blank_char(user)
      _camp = campaign(user, %{character_ids: [mira.id]})

      {:ok, view, _} = live(conn, ~p"/authoring/character/#{mira.id}")

      add_boundary(view, %{
        "topic" => "naming her father",
        "direction" => "refusal",
        "stance" => "open",
        "category" => ""
      })

      save(view)
      [saved] = Library.payload(Library.get(mira.id)).boundaries

      # Pure characterization. Most boundaries are this, and the ceiling is about content
      # categories rather than about how firm a line is.
      assert %Boundary{stance: :open, category: nil} = saved
    end
  end
end
