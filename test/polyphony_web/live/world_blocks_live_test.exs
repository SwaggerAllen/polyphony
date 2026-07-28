defmodule PolyphonyWeb.WorldBlocksLiveTest do
  @moduledoc """
  The block-field editor on the world bible: setting/tone as paragraphs, rules and
  starting canon as line lists. Driven by the offline Mock.
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

  test "setting loads as paragraph blocks; rules stays a line list", %{conn: conn, user: user} do
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
    # rules is a single line-list textarea, one item per line.
    assert html =~ ~s(name="rules")
    assert html =~ "gravity is weak\ntime loops"
  end

  test "editing blocks + lines and saving round-trips to the domain struct", %{
    conn: conn,
    user: user
  } do
    entry = world(user, %WorldBible{name: "W", setting: "", rules: [], starting_canon: []})
    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    view |> element("button[phx-click=add_block][phx-value-field=setting]") |> render_click()

    view
    |> form("form[phx-submit=save]", %{
      "name" => "W",
      "b_setting" => ["A city of glass.", "It never stops raining."],
      "b_tone" => ["noir"],
      "rules" => "no magic\nno gods",
      "starting_canon" => "the bridge is out"
    })
    |> render_submit()

    bible = Library.payload(Library.get(entry.id))
    assert bible.setting == "A city of glass.\n\nIt never stops raining."
    assert bible.tone == "noir"
    assert bible.rules == ["no magic", "no gods"]
    assert bible.starting_canon == ["the bridge is out"]
  end

  test "expand appends a paragraph to a prose field", %{conn: conn, user: user} do
    entry =
      world(user, %WorldBible{name: "W", setting: "Only para.", rules: [], starting_canon: []})

    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    view |> element("button[phx-click=expand_field][phx-value-field=setting]") |> render_click()
    html = render_async(view)

    assert html =~ "Only para."
    assert length(Regex.scan(~r/name="b_setting\[\]"/, html)) == 2
  end

  test "generating the rules line field fills it", %{conn: conn, user: user} do
    entry = world(user, %WorldBible{name: "W", rules: [], starting_canon: []})
    {:ok, view, _html} = live(conn, ~p"/authoring/bible/#{entry.id}")

    view |> element("button[phx-click=generate_field][phx-value-field=rules]") |> render_click()
    html = render_async(view)

    refute html =~ ~r/<textarea name="rules"[^>]*>\s*<\/textarea>/
  end
end
