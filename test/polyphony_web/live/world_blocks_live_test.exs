defmodule PolyphonyWeb.WorldBlocksLiveTest do
  @moduledoc """
  The block-field editor on the world bible: setting/tone as paragraph blocks, rules
  and starting canon as item blocks (one per block → the field's list). Driven by the
  offline Mock.
  """
  use PolyphonyWeb.ConnCase, async: false

  alias Polyphony.{Library, Owner}
  alias Polyphony.Authoring.WorldBible

  setup :register_and_log_in_user

  setup do
    previous = Application.get_env(:polyphony, :llm)
    Application.put_env(:polyphony, :llm, provider: Polyphony.LLM.Mock)
    on_exit(fn -> Application.put_env(:polyphony, :llm, previous) end)
    :ok
  end

  defp world(user, bible),
    do: Library.put(%{owner: Owner.of(user), kind: "world_bible", payload: bible})

  test "setting loads as paragraphs; rules loads one block per item", %{conn: conn, user: user} do
    entry =
      world(user, %WorldBible{
        name: "Neon Bay",
        setting: "A drowned port.\n\nMemory is currency.",
        rules: ["gravity is weak", "time loops"],
        starting_canon: []
      })

    {:ok, _view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    assert length(Regex.scan(~r/name="b_setting\[\]"/, html)) == 2
    assert html =~ "Memory is currency."
    # Each rule is its own block.
    assert length(Regex.scan(~r/name="b_rules\[\]"/, html)) == 2
    assert html =~ "gravity is weak"
    assert html =~ "time loops"
  end

  test "editing blocks saves prose as a string and lists as a list", %{conn: conn, user: user} do
    entry = world(user, %WorldBible{name: "W", setting: "", rules: [], starting_canon: []})
    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    view
    |> form("form[phx-submit=save]", %{
      "name" => "W",
      "b_setting" => ["A city of glass.", "It never stops raining."],
      "b_tone" => ["noir"],
      "b_rules" => ["no magic", "no gods"],
      "b_starting_canon" => ["the bridge is out"]
    })
    |> render_submit()

    bible = Library.payload(Library.get(entry.id))
    assert bible.setting == "A city of glass.\n\nIt never stops raining."
    assert bible.tone == "noir"
    assert bible.rules == ["no magic", "no gods"]
    assert bible.starting_canon == ["the bridge is out"]
  end

  test "expand adds an item to a line-list field", %{conn: conn, user: user} do
    entry = world(user, %WorldBible{name: "W", rules: ["gravity is weak"], starting_canon: []})
    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    view |> element("button[phx-click=expand_field][phx-value-field=rules]") |> render_click()
    html = render_async(view)

    assert html =~ "gravity is weak"
    assert length(Regex.scan(~r/name="b_rules\[\]"/, html)) == 2
  end

  test "regenerating one rule rewrites just that item", %{conn: conn, user: user} do
    entry = world(user, %WorldBible{name: "W", rules: ["placeholder rule"], starting_canon: []})
    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    view
    |> element("button[phx-click='generate_block'][phx-value-field='rules'][phx-value-index='0']")
    |> render_click()

    html = render_async(view)
    refute html =~ ">placeholder rule</textarea>"
    assert length(Regex.scan(~r/name="b_rules\[\]"/, html)) == 1
  end

  test "navigation is guarded only once there are unsaved edits", %{conn: conn, user: user} do
    entry = world(user, %WorldBible{name: "W", rules: [], starting_canon: []})
    {:ok, view, html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    refute html =~ "data-confirm"

    view |> element("button[phx-click=add_block][phx-value-field=rules]") |> render_click()
    assert render(view) =~ "data-confirm=\"You have unsaved changes"

    view |> form("form[phx-submit=save]", %{name: "W"}) |> render_submit()
    refute render(view) =~ "data-confirm"
  end
end
