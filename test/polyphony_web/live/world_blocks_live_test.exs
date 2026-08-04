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

    test "adding one happens in the list it adds to, and persists on save",
         %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W"})
      {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      # Closed, the add affordance is the box it has always been.
      assert html =~ "Add a rule…"
      refute html =~ ~s(id="new-rules")

      html = view |> element("button[phx-click=panel][phx-value-panel=rules]") |> render_click()

      # Open, that box *is* the input — it used to open a separate sheet below the
      # whole bible form, far enough from the list that the two didn't read as one
      # thing. Sitting inside `#rules` is what makes them one thing.
      assert has_element?(view, "#rules #new-rules")
      # The box became the input rather than growing a second one beside it. (The
      # string survives as the input's screen-reader label, so this asks for the
      # button, not for the words.)
      refute has_element?(view, "button[phx-click=panel][phx-value-panel=rules]")
      assert html =~ "Add something that's true…" or html =~ "Add something that&#39;s true…"

      view
      |> form("form[phx-submit=add_item]", %{field: "rules", statement: "No magic."})
      |> render_submit()

      view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()

      assert [%Entry{statement: "No magic.", concealed: false}] = bible_of(entry).rules
    end

    test "the add control belongs to its own form, not to the bible's",
         %{conn: conn, user: user} do
      entry = world(user, %WorldBible{name: "W"})
      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")
      view |> element("button[phx-click=panel][phx-value-panel=rules]") |> render_click()

      # The input sits inside `#bible-form` — a form cannot be nested in a form — so
      # `form=` is the only thing standing between pressing Enter here and submitting
      # the *bible*, losing what was typed. Dropping the attribute leaves markup that
      # still looks right and an interaction that quietly does the wrong thing.
      assert has_element?(view, "#bible-form #new-rules"),
             "the input no longer sits inside the bible form — if that is deliberate, " <>
               "the form= association is redundant and this test should go"

      assert has_element?(view, ~s(#new-rules[form="item-form"]))
      assert has_element?(view, ~s(button[type="submit"][form="item-form"]))

      # And the owner it points at exists, carries no markup, and is not nested.
      assert has_element?(view, "form#item-form")
      refute has_element?(view, "form#item-form *")
      refute has_element?(view, "#bible-form form#item-form")
    end

    test "an item's menu opens in the flow, where a sheet cannot clip it",
         %{conn: conn, user: user} do
      entry =
        world(user, %WorldBible{
          name: "W",
          starting_canon: [%Entry{statement: "the bridge is out"}]
        })

      {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

      # The kit's `.sheet` is `overflow:hidden` — it is what rounds the corners — so an
      # absolutely-positioned menu was clipped by the sheet's bottom edge, and the
      # items nearest that edge were exactly the ones whose menus you could not read.
      assert has_element?(view, "#starting_canon details nav.sheet")
      refute has_element?(view, "#starting_canon details nav.absolute")
      refute has_element?(view, "#starting_canon details nav.top-full")

      # The whole row opens it, not the ⋯ alone: a fourteen-pixel target is not a
      # phone affordance, and this screen is used on one.
      assert has_element?(view, "#starting_canon details summary", "the bridge is out")

      # The menu is still reachable and still does what it did.
      assert has_element?(
               view,
               "#starting_canon details nav button[phx-click=toggle_secret]"
             )
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
