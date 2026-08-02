defmodule PolyphonyWeb.CampaignContentLiveTest do
  @moduledoc """
  The campaign's content/maturity ceiling (§A5, layer 2): the editor controls, and the
  end-to-end effect that starting a scene caps a character's categorized boundary closed
  unless the campaign enables that category.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.CharacterSheet
  alias Polyphony.Authoring.CharacterSheet.Boundary
  alias Polyphony.Content.CampaignConfig
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
    {:ok, view, _} = live(conn, ~p"/campaigns/#{camp.id}")

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
end
