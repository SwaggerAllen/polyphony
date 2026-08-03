defmodule PolyphonyWeb.WorldBlocksLiveTest do
  @moduledoc """
  The two kinds of field on the world bible, which the port stopped treating as one.

  Setting and tone are **prose**, edited as paragraph blocks with Rewrite and Expand.
  Rules and what's-already-true are **lists**, edited as items with their own menu —
  secret, move up, delete. `ux/polyphony-world.html` §01 and §04 draw them
  differently because they *are* different: a rule is one statement you reorder, a
  paragraph is prose you rewrite. The old editor made both stacks of textareas, which
  is why reordering and the secret control had nowhere to live.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible
  alias Polyphony.Authoring.WorldBible.Entry

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp world(user, bible),
    do: Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})

  defp bible_of(entry), do: Library.payload(Library.get(entry.id))

  describe "prose fields" do
    test "load as paragraph blocks", %{conn: conn, user: user} do
      entry =
        world(user, %WorldBible{
          name: "Neon Bay",
          setting: "A drowned port.\n\nMemory is currency."
        })

      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      assert length(Regex.scan(~r/name="b_setting\[\]"/, html)) == 2
      assert html =~ "Memory is currency."
    end

    test "save joined by blank lines", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> form("form[phx-submit=save]", %{
        "name" => "W",
        "b_setting" => ["A city of glass.", "It never stops raining."],
        "b_tone" => ["noir"]
      })
      |> render_submit()

      assert bible_of(entry).setting == "A city of glass.\n\nIt never stops raining."
      assert bible_of(entry).tone == "noir"
    end

    test "expand appends a paragraph without touching the others", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W", setting: "A drowned port."})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view |> element("button[phx-click=expand_field][phx-value-field=setting]") |> render_click()
      html = render_async(view)

      assert html =~ "A drowned port."
      assert length(Regex.scan(~r/name="b_setting\[\]"/, html)) == 2
    end

    test "regenerating one paragraph rewrites just that one", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W", setting: "placeholder"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element(
        "button[phx-click='generate_block'][phx-value-field='setting'][phx-value-index='0']"
      )
      |> render_click()

      html = render_async(view)
      refute html =~ ">placeholder</textarea>"
      assert length(Regex.scan(~r/name="b_setting\[\]"/, html)) == 1
    end
  end

  describe "list fields" do
    test "are items, not textareas — the menu is where the controls live",
         %{conn: conn, user: user} do
      entry =
        world(user, %WorldBible{
          name: "Neon Bay",
          rules: [%Entry{statement: "gravity is weak"}, %Entry{statement: "time loops"}]
        })

      {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      refute html =~ ~s(name="b_rules[]")
      assert html =~ "gravity is weak"
      assert html =~ "time loops"
      assert html =~ ~s(phx-click="toggle_secret")
      assert html =~ ~s(phx-click="move_item")
    end

    test "adding one goes through a panel and persists on save", %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W"})
      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      refute html =~ ~s(phx-submit="add_item")

      view |> element("button[phx-click=panel][phx-value-panel=rules]") |> render_click()

      view
      |> form("form[phx-submit=add_item]", %{field: "rules", statement: "No magic."})
      |> render_submit()

      view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()

      assert [%Entry{statement: "No magic.", concealed: false}] = bible_of(entry).rules
    end

    test "order is authored, and Move up saturates rather than wrapping",
         %{conn: conn, user: user} do
      entry =
        world(user, %WorldBible{
          name: "W",
          rules: [%Entry{statement: "first"}, %Entry{statement: "second"}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element(
        "button[phx-click=move_item][phx-value-field=rules][phx-value-index='1'][phx-value-by='-1']"
      )
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()
      assert WorldBible.statements(bible_of(entry).rules) == ["second", "first"]

      # The top item's Move up does nothing rather than sending it to the bottom.
      view
      |> element(
        "button[phx-click=move_item][phx-value-field=rules][phx-value-index='0'][phx-value-by='-1']"
      )
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()
      assert WorldBible.statements(bible_of(entry).rules) == ["second", "first"]
    end

    test "an item can be deleted", %{conn: conn, user: user} do
      entry =
        world(user, %WorldBible{
          name: "W",
          starting_canon: [%Entry{statement: "the bridge is out"}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element(
        "button[phx-click=remove_item][phx-value-field=starting_canon][phx-value-index='0']"
      )
      |> render_click()

      view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()
      assert bible_of(entry).starting_canon == []
    end

    test "✦ Suggest appends what's new instead of replacing an authored list",
         %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W", rules: [%Entry{statement: "no magic"}]})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      view
      |> element("button[phx-click=suggest_items][phx-value-field=rules]")
      |> render_click()

      render_async(view)
      view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()

      statements = WorldBible.statements(bible_of(entry).rules)
      # The authored rule is still there, still first.
      assert hd(statements) == "no magic"
      assert length(statements) > 1
    end
  end

  test "navigation is guarded only once there are unsaved edits", %{conn: conn, user: user} do
    entry = world(user, %WorldBible{name: "W"})
    {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    refute html =~ "data-confirm=\"You have unsaved changes"

    view |> element("button[phx-click=add_block][phx-value-field=setting]") |> render_click()
    assert render(view) =~ "data-confirm=\"You have unsaved changes"

    view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()
    refute render(view) =~ "data-confirm=\"You have unsaved changes"
  end
end
